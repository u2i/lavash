defmodule Lavash.Dsl.Graph do
  @moduledoc """
  Builds and caches a `Lavash.Rx.Graph` from DSL module metadata.

  This is the bridge between Spark DSL modules and the standalone
  `Lavash.Reactive` engine. It reads persisted field specs and state
  declarations, compiles them into a `%Rx.Graph{}`, and caches
  the result in `persistent_term`.
  """

  alias Lavash.Rx.Graph, as: ReactiveGraph
  alias Lavash.Socket, as: LSocket

  @doc """
  Returns a cached `%Rx.Graph{}` for the given DSL module.
  """
  def compiled_graph(module) do
    case :persistent_term.get(cache_key(module), nil) do
      nil ->
        graph = build_graph(module)
        :persistent_term.put(cache_key(module), graph)
        graph

      graph ->
        graph
    end
  end

  @doc """
  Drops the cached graph for the given module.

  Takes an `Macro.Env` and the module's bytecode so it matches the
  `@after_compile` callback shape. Lavash modules wire this in via
  `build_cache_invalidation_ast/0` in their compile transformers so a hot
  recompile in dev replaces the cached graph instead of leaving the stale
  one in place.
  """
  def erase(%Macro.Env{module: module}, _bytecode) do
    :persistent_term.erase(cache_key(module))
    :ok
  end

  defp cache_key(module), do: {__MODULE__, module}

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

    %{
      graph
      | dep_resolvers: %{
          __actor__: fn socket -> socket.assigns[:current_user] end,
          __all_state__: &LSocket.full_state/1
        }
    }
  end
end
