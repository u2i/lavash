defmodule Lavash.Dsl.Graph do
  @moduledoc """
  Builds and caches a `Lavash.Reactive.Graph` from DSL module metadata.

  This is the bridge between Spark DSL modules and the standalone
  `Lavash.Reactive` engine. It reads persisted field specs and state
  declarations, compiles them into a `%Reactive.Graph{}`, and caches
  the result in `persistent_term`.
  """

  alias Lavash.Reactive.Graph, as: ReactiveGraph
  alias Lavash.Socket, as: LSocket

  @doc """
  Returns a cached `%Reactive.Graph{}` for the given DSL module.
  """
  def compiled_graph(module) do
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

  @doc """
  Returns field names that depend on reads/forms of a given resource.
  Used for resource-centric invalidation when a child component mutates a resource.
  """
  def fields_for_resource(module, resource) do
    Lavash.Reactive.fields_with_tag(compiled_graph(module), {:resource, resource})
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
