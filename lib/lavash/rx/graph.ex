defmodule Lavash.Rx.Graph do
  @moduledoc """
  Reactive graph runtime for DSL-declared LiveViews and Components.

  Builds a `Lavash.Reactive.Graph` once per module (cached in persistent_term)
  from the `__lavash__(:derived_fields)` metadata emitted by the Spark pipeline.
  Field expansion (reads, forms, calculations → Derived.Field structs) happens
  at compile time in `Lavash.Transformers.ExpandFields`.

  Delegates all recomputation to `Lavash.Reactive`.
  """

  alias Lavash.Reactive
  alias Lavash.Reactive.Graph, as: ReactiveGraph
  alias Lavash.Socket, as: LSocket

  # --- Public API (signatures unchanged, all call sites untouched) ---

  def recompute_all(socket, module) do
    Reactive.recompute_all(socket, compiled_graph(module))
  end

  def recompute_dirty(socket, module) do
    Reactive.recompute_dirty(socket, compiled_graph(module))
  end

  def recompute_dependents(socket, module, changed_field) do
    Reactive.recompute_dependents(socket, compiled_graph(module), changed_field)
  end

  @doc """
  Returns field names that depend on reads/forms of a given resource.
  Used for resource-centric invalidation when a child component mutates a resource.
  """
  def fields_for_resource(module, resource) do
    Reactive.fields_with_tag(compiled_graph(module), {:resource, resource})
  end

  # --- Graph building + caching ---

  defp compiled_graph(module) do
    key = {__MODULE__, module}

    case :persistent_term.get(key, nil) do
      nil ->
        graph = build_graph(module)
        :persistent_term.put(key, graph)
        graph

      graph ->
        graph
    end
  end

  defp build_graph(module) do
    fields = Lavash.Transformers.ExpandFields.build_fields(module)
    states = module.__lavash__(:states)
    state_tuples = Enum.map(states, fn s -> {s.name, s.default} end)

    derive_tuples =
      Enum.map(fields, fn field ->
        tags = (field.reads || []) |> Enum.map(&{:resource, &1})
        {field.name, field.depends_on, field.compute, field.async || false, tags}
      end)

    graph = ReactiveGraph.compile(state_tuples, derive_tuples)

    %{graph | dep_resolvers: %{
      __actor__: fn socket -> socket.assigns[:current_user] end,
      __all_state__: &LSocket.full_state/1
    }}
  end
end
