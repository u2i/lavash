defmodule Lavash.ClientState do
  @moduledoc """
  Runtime for `client_state` projections — mapping a query read's
  record list into JSON-safe maps shipped to the client as
  optimistic state.

  See `Lavash.Read.ClientState` for the DSL and semantics. The
  projected field is a derive on the server (recomputed from the
  read, never mutated by actions) and mutable optimistic state on
  the client.
  """

  @doc """
  Projects a list of records through a field allowlist into plain
  maps with wire-safe values.

  `fields` mixes atoms (own attributes) and keyword tails
  (`assoc: [subfields]`) for one level of loaded relationships.
  A `nil` record list projects to `[]`.
  """
  def project(nil, _fields), do: []

  def project(records, fields) when is_list(records) do
    Enum.map(records, &project_record(&1, fields))
  end

  @doc """
  Returns the client-state projections declared on a module's reads,
  as `%{name, read, key, resource, fields, stream}` maps.
  """
  def projections(module) do
    module.__lavash__(:reads)
    |> Enum.flat_map(fn read ->
      Enum.map(read.client_states || [], fn cs ->
        %{
          name: cs.name,
          read: read.name,
          key: cs.key,
          resource: read.resource,
          fields: cs.fields,
          stream: Map.get(cs, :stream, false)
        }
      end)
    end)
  end

  @doc """
  The projection fields an action mutates via `mutate`/`remove`/`append`.

  Uses `Map.get` — injected actions (overlay `:noop`, synthetic setters)
  can be plain maps without these keys.
  """
  def mutated_fields(action) do
    Enum.map(Map.get(action, :mutates) || [], & &1.field) ++
      Enum.map(Map.get(action, :removes) || [], & &1.field) ++
      Enum.map(Map.get(action, :appends) || [], & &1.field) ++
      Enum.map(Map.get(action, :upserts) || [], & &1.field)
  end

  @doc """
  Returns the backing read names for projections targeted by an
  action's `mutate`/`remove`/`append` ops. The runtime marks these
  dirty pre-cascade so the same event's diff carries post-write
  truth — the client's prediction confirms against it instead of a
  stale list.
  """
  def reads_to_refresh(module, action) do
    fields = MapSet.new(mutated_fields(action))

    if MapSet.size(fields) == 0 do
      []
    else
      # Streamed projections don't confirm via a full re-read — the
      # touched rows are pushed as per-row stream ops from the same
      # event (see apply_mutations).
      module
      |> projections()
      |> Enum.filter(&(MapSet.member?(fields, &1.name) and not &1.stream))
      |> Enum.map(& &1.read)
      |> Enum.uniq()
    end
  end

  @doc """
  Executes an action's `mutate`/`remove`/`append` ops against their
  Ash resources. Runs pre-cascade (after sets/pre_runs, before the
  reactive recompute), so the re-read triggered by
  `reads_to_refresh/2` sees post-write data in the same event.

  Broadcasts each touched resource once via `Lavash.PubSub` so
  other sessions' reads invalidate.

  `append_ids` maps `"Module:action:field"` keys to client-generated
  UUIDs (see `Lavash.Action.Runtime.parse_append_ids/1`). When an
  append op finds its key, the record is created under that id, so
  the client's provisional row and the persisted record share
  identity — no temp-id churn when the re-read lands.
  """
  def apply_mutations(socket, action, params, module, append_ids \\ %{}) do
    ops =
      Enum.map(Map.get(action, :mutates) || [], &{:mutate, &1}) ++
        Enum.map(Map.get(action, :removes) || [], &{:remove, &1}) ++
        Enum.map(Map.get(action, :appends) || [], &{:append, &1}) ++
        Enum.map(Map.get(action, :upserts) || [], &{:upsert, &1})

    if ops == [] do
      socket
    else
      projections_by_field = Map.new(projections(module), &{&1.name, &1})

      # Component props resolve in transforms too (@cart_id etc.) —
      # full_state only covers state + derives. LiveViews don't define
      # __lavash__(:props), hence the rescue.
      prop_values =
        try do
          module.__lavash__(:props)
          |> Map.new(fn prop -> {prop.name, Map.get(socket.assigns, prop.name)} end)
        rescue
          FunctionClauseError -> %{}
        end

      state =
        prop_values
        |> Map.merge(Lavash.Socket.full_state(socket))
        |> Map.merge(params)

      {socket, touched} =
        Enum.reduce(ops, {socket, []}, fn {kind, op}, {sock, acc} ->
          proj = Map.fetch!(projections_by_field, op.field)

          sock =
            case kind do
              :append ->
                id = Map.get(append_ids, append_id_key(module, action.name, op.field))
                record = apply_append(op, proj, state, module, id)
                confirm_stream_insert(sock, proj, record)

              :upsert ->
                id = Map.get(append_ids, append_id_key(module, action.name, op.field))
                apply_upsert(op, proj, state, module, id)
                sock

              _ ->
                apply_mutation(kind, op, proj, state, params, module)
                sock
            end

          {sock, [proj.resource | acc]}
        end)

      touched |> Enum.uniq() |> Enum.each(&Lavash.PubSub.broadcast/1)
      socket
    end
  end

  # Streamed projection (issue #71): the same-event confirmation is a
  # per-row stream op of the written record — the client's predicted
  # row rendered under the same client-generated id, so LiveView's
  # insert morphs that exact node in place (and strips the client's
  # data-lavash-provisional marker, which IS the confirm signal).
  defp confirm_stream_insert(socket, %{stream: true} = proj, record) do
    Phoenix.LiveView.stream_insert(socket, proj.name, project_record(record, proj.fields))
  end

  defp confirm_stream_insert(socket, _proj, _record), do: socket

  @doc """
  Feeds fresh results of stream-backed projections (issue #71) into
  their LiveView streams and releases the read's records from assigns.

  Called after each reactive recompute: whenever a streamed
  projection's backing read holds a fresh record list (initial mount,
  PubSub invalidation re-read), the projected rows are streamed with
  `reset: true` and the assign is collapsed to `:streamed` so neither
  side retains the list.
  """
  def flush_stream_projections(socket, module) do
    module
    |> projections()
    |> Enum.filter(& &1.stream)
    |> Enum.reduce(socket, fn proj, sock ->
      case sock.assigns[proj.read] do
        records when is_list(records) ->
          sock
          |> Phoenix.LiveView.stream(proj.name, project(records, proj.fields), reset: true)
          |> Lavash.Socket.put_derived(proj.read, :streamed)

        _ ->
          sock
      end
    end)
  end

  defp apply_mutation(:mutate, op, proj, state, params, module) do
    record = fetch_record!(proj, params)

    case eval_rx(module, op.transform, Map.put(state, :item, record)) do
      :remove ->
        Ash.destroy!(record)

      attrs when is_map(attrs) ->
        record
        |> Ash.Changeset.for_update(op.action, attrs)
        |> Ash.update!()
    end
  end

  defp apply_mutation(:remove, op, proj, _state, params, _module) do
    record = fetch_record!(proj, params)

    if op.action do
      record |> Ash.Changeset.for_destroy(op.action) |> Ash.destroy!()
    else
      Ash.destroy!(record)
    end
  end

  defp apply_append(op, proj, state, module, id) do
    create_record(proj, op.action, op.transform, state, module, id)
  end

  # Match against the backing read's CURRENT records — the same list
  # the client's copy projects from, so both sides decide the branch
  # from the same basis (modulo in-flight writes from other sessions,
  # which the same-event re-read reconciles). Comparison is
  # string-tolerant like the client's (`String(a) === String(b)`) —
  # wire params arrive as strings.
  defp apply_upsert(op, proj, state, module, id) do
    records = List.wrap(Map.get(state, proj.read))

    matched =
      Enum.find(records, fn record ->
        Enum.all?(op.match, fn key ->
          to_string(Map.get(record, key)) == to_string(Map.get(state, key))
        end)
      end)

    if matched do
      {action, transform} = op.on_conflict

      case eval_rx(module, transform, Map.put(state, :item, matched)) do
        :remove ->
          Ash.destroy!(matched)

        attrs when is_map(attrs) ->
          matched
          |> Ash.Changeset.for_update(action, attrs)
          |> Ash.update!()
      end
    else
      {action, transform} = op.on_insert
      create_record(proj, action, transform, state, module, id)
    end
  end

  defp create_record(proj, action, transform, state, module, id) do
    attrs = eval_rx(module, transform, state)
    accepted = accepted_attrs(proj.resource, action)
    attrs = if accepted, do: Map.take(attrs, accepted), else: attrs

    proj.resource
    |> Ash.Changeset.for_create(action, attrs)
    |> force_append_id(id)
    |> Ash.create!()
  end

  # The id came over the wire — only honor well-formed UUIDs, and
  # force_change so a non-accepted/non-writable pk still takes it.
  defp force_append_id(changeset, id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Ash.Changeset.force_change_attribute(changeset, :id, uuid)
      :error -> changeset
    end
  end

  defp force_append_id(changeset, _id), do: changeset

  # Must mirror the key the generated JS stashes ids under
  # (`ExtractColocatedJs.append_id_key/3`).
  defp append_id_key(module, action_name, field) do
    "#{inspect(module)}:#{action_name}:#{field}"
  end

  defp fetch_record!(proj, params) do
    key_value = Map.fetch!(params, proj.key)
    Ash.get!(proj.resource, key_value)
  end

  defp eval_rx(module, %Lavash.Rx{ast: ast}, state) do
    Lavash.Rx.Cache.compile_rx(module, ast).(state)
  end

  defp accepted_attrs(resource, action_name) do
    case Ash.Resource.Info.action(resource, action_name) do
      %{accept: accept} = action when is_list(accept) ->
        # Arguments are part of the action's input surface too — an
        # `:add` taking cart_id/product_id as arguments must receive
        # them, not have them filtered away.
        accept ++ Enum.map(Map.get(action, :arguments) || [], & &1.name)

      _ ->
        nil
    end
  end

  defp project_record(record, fields) do
    Enum.reduce(fields, %{}, fn
      field, acc when is_atom(field) ->
        Map.put(acc, field, encode(Map.get(record, field)))

      {assoc, subfields}, acc ->
        Map.put(acc, assoc, project_assoc(Map.get(record, assoc), subfields))
    end)
  end

  defp project_assoc(nil, _subfields), do: nil
  defp project_assoc(%Ash.NotLoaded{}, _subfields), do: nil
  defp project_assoc(records, subfields) when is_list(records), do: project(records, subfields)
  defp project_assoc(record, subfields), do: project_record(record, subfields)

  defp encode(%Decimal{} = d), do: Decimal.to_string(d)
  defp encode(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp encode(%Date{} = d), do: Date.to_iso8601(d)
  defp encode(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
  defp encode(v) when is_atom(v) and not is_boolean(v) and not is_nil(v), do: to_string(v)
  defp encode(v), do: v
end
