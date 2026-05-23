defmodule Lavash.Rx.Graph do
  @moduledoc """
  A precomputed reactive dependency graph.

  Built at compile time (via module attribute) or at runtime,
  then passed to `Lavash.Reactive` functions to drive state updates.

  The graph contains:
  - `topo_order` — derived fields in topological order for recomputation
  - `dependents` — reverse index: field → list of derived fields that depend on it
  - `deps` — forward index: derived field → list of fields it depends on
  - `compute_fns` — derived field → function that computes it from deps
  - `state_defaults` — state field → default value
  - `tags` — reverse index: tag → MapSet of field names (for resource invalidation, etc.)
  """

  defstruct topo_order: [],
            dependents: %{},
            deps: %{},
            compute_fns: %{},
            state_defaults: %{},
            async_fields: MapSet.new(),
            tags: %{},
            dep_resolvers: %{}

  @doc """
  Compiles states and derives into a frozen `%Graph{}`.

  States: `[{name, default}, ...]`
  Derives: `[{name, [dep, ...], fun, async?} | {name, [dep, ...], fun, async?, [tag]}]`

  The function for each derive receives a map of dependency values:
  `fn %{count: 5, step: 2} -> 10 end`
  """
  def compile(states, derives) do
    # Normalize 4-tuples to 5-tuples
    derives =
      Enum.map(derives, fn
        {name, dep_list, fun, async, tags} -> {name, dep_list, fun, async, tags}
        {name, dep_list, fun, async} -> {name, dep_list, fun, async, []}
      end)

    state_defaults = Map.new(states)

    deps = Map.new(derives, fn {name, dep_list, _, _, _} -> {name, dep_list} end)
    compute_fns = Map.new(derives, fn {name, _, fun, _, _} -> {name, fun} end)

    async_fields =
      derives
      |> Enum.filter(fn {_, _, _, async, _} -> async end)
      |> MapSet.new(fn {name, _, _, _, _} -> name end)

    tags = build_tags(derives)
    topo_order = Lavash.Graph.topo_sort(deps)
    dependents = Lavash.Graph.build_dependents(deps)

    %__MODULE__{
      topo_order: topo_order,
      dependents: dependents,
      deps: deps,
      compute_fns: compute_fns,
      state_defaults: state_defaults,
      async_fields: async_fields,
      tags: tags
    }
  end

  @doc """
  Returns all derived fields transitively affected by the given dirty fields.
  """
  def affected(graph, dirty_fields) do
    Lavash.Graph.transitive_dependents(graph.dependents, dirty_fields)
    |> MapSet.to_list()
  end

  @doc """
  Filters topo_order to only the affected fields, preserving correct evaluation order.
  """
  def recompute_order(graph, dirty_fields) do
    affected = affected(graph, dirty_fields) |> MapSet.new()
    Enum.filter(graph.topo_order, &MapSet.member?(affected, &1))
  end

  @doc """
  Returns field names that have the given tag.
  """
  def fields_with_tag(graph, tag) do
    graph.tags
    |> Map.get(tag, MapSet.new())
    |> MapSet.to_list()
  end

  # Build reverse tag index: %{tag => MapSet.t(field_name)}
  defp build_tags(derives) do
    Enum.reduce(derives, %{}, fn {name, _, _, _, tags}, acc ->
      Enum.reduce(tags, acc, fn tag, inner_acc ->
        Map.update(inner_acc, tag, MapSet.new([name]), &MapSet.put(&1, name))
      end)
    end)
  end
end
