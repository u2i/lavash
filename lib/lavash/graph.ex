defmodule Lavash.Graph do
  @moduledoc """
  Pure graph algorithms for dependency graphs.

  All functions operate on a deps map: `%{name => [deps]}` where each key
  is a derived field and the value is the list of fields it depends on.

  Used by:
  - `Rx.Graph` — runtime reactive graph
  - `ColocatedTransformer` — compile-time JS metadata generation
  - `GraphMacro` — defgraph compile-time JS generation
  - JS hook (`lavash_optimistic.js`) — consumes the serialized output client-side
  """

  @doc """
  Topological sort via Kahn's algorithm.

  Returns derived field names in dependency order (leaves first).
  State fields (names not in the deps map keys) are ignored.

      iex> Lavash.Graph.topo_sort(%{doubled: [:count], quad: [:doubled]})
      [:doubled, :quad]
  """
  def topo_sort(deps_map) when is_map(deps_map) do
    names = Map.keys(deps_map)
    derive_names = MapSet.new(names)

    in_degree =
      Map.new(names, fn name ->
        count = deps_map[name] |> Enum.count(&MapSet.member?(derive_names, &1))
        {name, count}
      end)

    queue = for {name, 0} <- in_degree, do: name
    kahn(queue, in_degree, deps_map, derive_names, [])
  end

  @doc """
  Reverse dependency index.

  Returns `%{field => [derived fields that depend on it]}`.

      iex> Lavash.Graph.build_dependents(%{doubled: [:count], quad: [:doubled]})
      %{count: [:doubled], doubled: [:quad]}
  """
  def build_dependents(deps_map) when is_map(deps_map) do
    Enum.reduce(deps_map, %{}, fn {name, dep_list}, acc ->
      Enum.reduce(dep_list, acc, fn dep, inner_acc ->
        Map.update(inner_acc, dep, [name], &[name | &1])
      end)
    end)
  end

  @doc """
  BFS to find all fields transitively affected by `changed_fields`.

  Uses the `dependents` map (output of `build_dependents/1`).

      iex> dependents = %{count: [:doubled], doubled: [:quad]}
      iex> Lavash.Graph.transitive_dependents(dependents, [:count])
      MapSet.new([:doubled, :quad])
  """
  def transitive_dependents(dependents, changed_fields) do
    do_transitive(dependents, changed_fields, MapSet.new())
  end

  defp do_transitive(_dependents, [], visited), do: visited

  defp do_transitive(dependents, [field | rest], visited) do
    direct = Map.get(dependents, field, [])
    new = Enum.reject(direct, &MapSet.member?(visited, &1))
    visited = Enum.reduce(new, visited, &MapSet.put(&2, &1))
    do_transitive(dependents, rest ++ new, visited)
  end

  # Kahn's algorithm internals
  defp kahn([], _in_degree, _deps_map, _derive_names, result), do: Enum.reverse(result)

  defp kahn([node | rest], in_degree, deps_map, derive_names, result) do
    dependents =
      for {name, dep_list} <- deps_map,
          node in dep_list,
          MapSet.member?(derive_names, name),
          do: name

    {in_degree, new_ready} =
      Enum.reduce(dependents, {in_degree, []}, fn dep, {deg, ready} ->
        new_deg = Map.update!(deg, dep, &(&1 - 1))
        if new_deg[dep] == 0, do: {new_deg, [dep | ready]}, else: {new_deg, ready}
      end)

    kahn(rest ++ new_ready, in_degree, deps_map, derive_names, [node | result])
  end
end
