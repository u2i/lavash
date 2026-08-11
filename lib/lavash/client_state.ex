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
  as `%{name, read, key, resource}` maps.
  """
  def projections(module) do
    module.__lavash__(:reads)
    |> Enum.flat_map(fn read ->
      Enum.map(read.client_states || [], fn cs ->
        %{name: cs.name, read: read.name, key: cs.key, resource: read.resource}
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
      Enum.map(Map.get(action, :appends) || [], & &1.field)
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
      module
      |> projections()
      |> Enum.filter(&MapSet.member?(fields, &1.name))
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
        Enum.map(Map.get(action, :appends) || [], &{:append, &1})

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

      touched =
        Enum.map(ops, fn {kind, op} ->
          proj = Map.fetch!(projections_by_field, op.field)

          case kind do
            :append ->
              id = Map.get(append_ids, append_id_key(module, action.name, op.field))
              apply_append(op, proj, state, module, id)

            _ ->
              apply_mutation(kind, op, proj, state, params, module)
          end

          proj.resource
        end)

      touched |> Enum.uniq() |> Enum.each(&Lavash.PubSub.broadcast/1)
      socket
    end
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
    attrs = eval_rx(module, op.transform, state)
    accepted = accepted_attrs(proj.resource, op.action)
    attrs = if accepted, do: Map.take(attrs, accepted), else: attrs

    proj.resource
    |> Ash.Changeset.for_create(op.action, attrs)
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
