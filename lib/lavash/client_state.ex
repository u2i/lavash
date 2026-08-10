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
  Returns the backing read names for projections targeted by an
  action's `map_by` ops. The runtime marks these dirty pre-cascade
  so the same event's diff carries post-write truth — the client's
  prediction confirms against it instead of a stale list.
  """
  def reads_to_refresh(module, action) do
    map_by_fields = MapSet.new(action.map_bys || [], & &1.field)

    if MapSet.size(map_by_fields) == 0 do
      []
    else
      module
      |> projections()
      |> Enum.filter(&MapSet.member?(map_by_fields, &1.name))
      |> Enum.map(& &1.read)
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
