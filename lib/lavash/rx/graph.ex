defmodule Lavash.Rx.Graph do
  @moduledoc """
  Reactive graph runtime for DSL-declared LiveViews and Components.

  Builds a `Lavash.Reactive.Graph` once per module (cached in persistent_term)
  from the `__lavash__(:derived_fields)` metadata emitted by the Spark pipeline.
  Field expansion (reads, forms, calculations → Derived.Field structs) happens
  at compile time in `Lavash.Transformers.ExpandFields`.

  This module handles only runtime concerns:
  - Graph caching
  - Dirty tracking and incremental recomputation
  - Async task management
  - Automatic propagation of special states (:loading, :error, nil)
  """

  alias Lavash.Socket, as: LSocket
  alias Lavash.Reactive.Graph, as: ReactiveGraph
  alias Phoenix.LiveView.AsyncResult

  # --- Public API (signatures unchanged, all call sites untouched) ---

  def recompute_all(socket, module) do
    graph = compiled_graph(module)
    recompute(socket, graph, graph.topo_order)
  end

  def recompute_dirty(socket, module) do
    dirty = LSocket.dirty(socket)

    if MapSet.size(dirty) == 0 do
      socket
    else
      graph = compiled_graph(module)
      dirty_list = MapSet.to_list(dirty)

      # Get derives transitively affected by dirty state fields
      affected = ReactiveGraph.affected(graph, dirty_list) |> MapSet.new()

      # Also include dirty fields that ARE derives (e.g. directly marked dirty for re-fetch)
      derive_names = MapSet.new(graph.topo_order)
      dirty_derives = MapSet.intersection(dirty, derive_names)
      all_affected = MapSet.union(affected, dirty_derives)

      # Filter topo_order to affected, preserving correct evaluation order
      to_recompute = Enum.filter(graph.topo_order, &MapSet.member?(all_affected, &1))

      socket = LSocket.clear_dirty(socket)
      recompute(socket, graph, to_recompute)
    end
  end

  def recompute_dependents(socket, module, changed_field) do
    graph = compiled_graph(module)
    to_recompute = ReactiveGraph.recompute_order(graph, [changed_field])
    recompute(socket, graph, to_recompute)
  end

  @doc """
  Returns field names that depend on reads/forms of a given resource.
  Used for resource-centric invalidation when a child component mutates a resource.
  """
  def fields_for_resource(module, resource) do
    graph = compiled_graph(module)
    ReactiveGraph.fields_with_tag(graph, {:resource, resource})
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
    explicit_fields = module.__lavash__(:derived_fields)
    expanded_fields = Lavash.Transformers.ExpandFields.build_fields(module)
    fields = explicit_fields ++ expanded_fields
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

  # --- Recompute engine ---

  defp recompute(socket, graph, fields) do
    Enum.reduce(fields, socket, fn field, sock ->
      compute_field(sock, graph, field)
    end)
  end

  defp compute_field(socket, graph, field) do
    dep_values = resolve_deps(socket, graph, field)

    case check_deps_state(dep_values) do
      {:propagate, state} ->
        LSocket.put_derived(socket, field, state)

      {:ready, had_async} ->
        unwrapped = unwrap_async_for_compute(dep_values)

        if MapSet.member?(graph.async_fields, field) do
          run_async(socket, graph, field, unwrapped)
        else
          result = graph.compute_fns[field].(unwrapped) |> maybe_wrap_changeset()
          final = if had_async, do: AsyncResult.ok(result), else: result
          LSocket.put_derived(socket, field, final)
        end
    end
  end

  defp resolve_deps(socket, graph, field) do
    resolvers = graph.dep_resolvers

    Map.new(graph.deps[field] || [], fn dep ->
      value =
        case Map.fetch(resolvers, dep) do
          {:ok, resolver_fn} -> resolver_fn.(socket)
          :error -> socket.assigns[dep]
        end

      {dep, value}
    end)
  end

  defp run_async(socket, graph, field, dep_values) do
    pid = self()
    compute_fn = graph.compute_fns[field]
    component_id = LSocket.get(socket, :component_id)

    if component_id do
      component_module = socket.assigns[:__component_module__]

      Task.start(fn ->
        result = compute_fn.(dep_values)
        send(pid, {:lavash_component_async, component_module, component_id, field, result})
      end)
    else
      Task.start(fn ->
        result = compute_fn.(dep_values)
        send(pid, {:lavash_async, field, result})
      end)
    end

    LSocket.put_derived(socket, field, AsyncResult.loading())
  end

  defp check_deps_state(deps) do
    Enum.reduce_while(deps, {:ready, false}, fn {_key, value}, {_status, had_async} ->
      case value do
        %AsyncResult{loading: loading} when loading != nil ->
          {:halt, {:propagate, AsyncResult.loading()}}

        %AsyncResult{failed: failed} when failed != nil ->
          {:halt, {:propagate, value}}

        %AsyncResult{ok?: true} ->
          {:cont, {:ready, true}}

        _ ->
          {:cont, {:ready, had_async}}
      end
    end)
  end

  defp unwrap_async_for_compute(deps) do
    Map.new(deps, fn {key, value} ->
      unwrapped =
        case value do
          %AsyncResult{ok?: true, result: result} -> result
          other -> other
        end

      {key, unwrapped}
    end)
  end

  defp maybe_wrap_changeset(%Ash.Changeset{} = changeset) do
    Lavash.Form.wrap(changeset)
  end

  defp maybe_wrap_changeset(other), do: other
end
