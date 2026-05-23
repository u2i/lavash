defmodule Lavash.Reactive do
  @moduledoc """
  Reactive state management for Phoenix LiveViews.

  Provides a builder API to define state fields and derived computations,
  producing a precomputed `%Graph{}` that drives automatic recomputation
  when state changes.

  The graph is stored on the socket during `init/2`, so subsequent calls
  don't need the graph passed explicitly.

  ## Usage

      defmodule MyLive do
        use Phoenix.LiveView
        import Lavash.Rx

        defp graph do
          Lavash.Reactive.graph(__MODULE__, fn ->
            Lavash.Reactive.new()
            |> Lavash.Reactive.state(:count, 0)
            |> Lavash.Reactive.state(:step, 1)
            |> Lavash.Reactive.derive(:doubled, rx(@count * 2))
            |> Lavash.Reactive.derive(:next, rx(@count + @step))
            |> Lavash.Reactive.build()
          end)
        end

        def mount(_params, _session, socket) do
          {:ok, Lavash.Reactive.init(socket, graph())}
        end

        def handle_event("inc", _, socket) do
          socket =
            socket
            |> Lavash.Reactive.put(:count, &(&1 + 1))
            |> Lavash.Reactive.recompute()

          {:noreply, socket}
        end

        # Required for async derives:
        def handle_info(msg, socket) do
          case Lavash.Reactive.handle_async(socket, msg) do
            {:ok, socket} -> {:noreply, socket}
            :not_handled -> {:noreply, socket}
          end
        end
      end

  `put/3` accepts a value or a function (`&(&1 + 1)`), marks the field
  dirty, and defers recomputation until `recompute/1` is called:

      socket
      |> Reactive.put(:search, "elixir")
      |> Reactive.put(:page, 1)
      |> Reactive.recompute()

  ## Async Derives

  Mark a derive as `async: true` to run its computation in a background task.
  The field is immediately set to `AsyncResult.loading()`, then updated when
  the task completes. Downstream derives automatically propagate loading and
  failed states.

      |> Reactive.derive(:results, rx(fetch_results(@search)), async: true)
      |> Reactive.derive(:count, rx(length(@results)))

  `graph/2` builds the graph once and caches it in `persistent_term`,
  so the topo sort only runs once per module for the entire app lifecycle.

  Note: anonymous functions cannot be stored in module attributes (`@graph`)
  due to BEAM escaping limitations. The `graph/2` + `persistent_term` approach
  achieves the same zero-cost-after-first-call behavior without macros.
  """

  alias Lavash.Rx.Graph
  alias Lavash.Socket, as: LSocket
  alias Phoenix.LiveView.AsyncResult

  # Builder struct — accumulates state/derive declarations before build()
  defstruct states: [], derives: [], dep_resolvers: %{}

  @doc """
  Creates a new reactive graph builder.
  """
  def new, do: %__MODULE__{}

  @doc """
  Registers a state field with a default value.
  """
  def state(%__MODULE__{} = builder, name, default) do
    %{builder | states: [{name, default} | builder.states]}
  end

  @doc """
  Registers a derived field with an `rx()` expression.

  Dependencies are auto-extracted from `@field` references, and the
  compute function is compiled in the caller's context (so private
  functions are accessible).

      import Lavash.Rx
      derive(builder, :doubled, rx(@count * 2))
      derive(builder, :fact, rx(factorial(@count)), async: true)

  Options:
    - `async: true` — computation runs in a background task. The field
      is set to `AsyncResult.loading()` immediately, then updated when
      the task completes. Downstream derives propagate loading/failed
      states automatically.
    - `tags: [term()]` — arbitrary tags for this field. The graph builds
      a reverse index so callers can query `Graph.fields_with_tag(graph, tag)`
      to find all fields with a given tag (e.g. for resource invalidation).
  """
  def derive(%__MODULE__{} = builder, name, %Lavash.Rx{} = rx) do
    derive(builder, name, rx, [])
  end

  def derive(%__MODULE__{} = builder, name, deps, fun) when is_list(deps) do
    derive(builder, name, deps, fun, [])
  end

  def derive(%__MODULE__{} = builder, name, %Lavash.Rx{} = rx, opts) when is_list(opts) do
    deps = normalize_rx_deps(rx.deps)
    compute_fn = compile_rx(rx.ast)
    async = Keyword.get(opts, :async, false)
    tags = Keyword.get(opts, :tags, [])
    %{builder | derives: [{name, deps, compute_fn, async, tags} | builder.derives]}
  end

  def derive(%__MODULE__{} = builder, name, deps, fun, opts)
      when is_list(deps) and is_list(opts) do
    async = Keyword.get(opts, :async, false)
    tags = Keyword.get(opts, :tags, [])
    %{builder | derives: [{name, deps, fun, async, tags} | builder.derives]}
  end

  @doc """
  Registers a custom dependency resolver.

  When a derive depends on a name that has a resolver, the resolver function
  is called with the socket to produce the value, instead of reading from
  `socket.assigns`.

  This is useful for synthetic dependencies like `:__actor__` or `:__all_state__`
  that don't correspond to actual assign keys.

      builder
      |> Reactive.dep_resolver(:__actor__, fn socket -> socket.assigns[:current_user] end)
      |> Reactive.dep_resolver(:__all_state__, &Lavash.Socket.full_state/1)
  """
  def dep_resolver(%__MODULE__{} = builder, name, fun) when is_function(fun, 1) do
    %{builder | dep_resolvers: Map.put(builder.dep_resolvers, name, fun)}
  end

  @doc """
  Finalizes the builder into a frozen `%Graph{}`.

  Performs topological sort and builds dependency indices.
  After this, the graph is immutable and ready for runtime use.
  """
  def build(%__MODULE__{} = builder) do
    graph = Graph.compile(Enum.reverse(builder.states), Enum.reverse(builder.derives))
    %{graph | dep_resolvers: builder.dep_resolvers}
  end

  # --- Graph caching ---

  @doc """
  Returns a cached `%Graph{}` for the given module.

  On first call, invokes `build_fn` to construct the graph, then stores
  it in `persistent_term`. Subsequent calls return the cached graph
  with zero overhead.

      defp graph do
        Lavash.Reactive.graph(__MODULE__, fn ->
          Lavash.Reactive.new()
          |> Lavash.Reactive.state(:count, 0)
          |> Lavash.Reactive.derive(:doubled, [:count], &(&1.count * 2))
          |> Lavash.Reactive.build()
        end)
      end
  """
  def graph(module, build_fn) do
    key = {__MODULE__, module}

    case :persistent_term.get(key, nil) do
      nil ->
        graph = build_fn.()
        :persistent_term.put(key, graph)
        graph

      graph ->
        graph
    end
  end

  # --- Runtime functions (operate on socket, graph retrieved from socket) ---

  @doc """
  Initializes a socket with the reactive graph.

  Stores the graph on the socket, sets all state defaults, and computes
  all derived values. Subsequent calls to `set/3`, `put/3`, etc. retrieve
  the graph from the socket automatically.
  """
  def init(socket, %Graph{} = graph) do
    socket =
      socket
      |> LSocket.init()
      |> LSocket.put(:graph, graph)

    # Set state defaults
    socket =
      Enum.reduce(graph.state_defaults, socket, fn {name, default}, sock ->
        LSocket.put_state(sock, name, default)
      end)

    # Compute all derived values in topo order
    run_recompute(socket, graph, graph.topo_order)
  end

  @doc """
  Sets a state field and marks it dirty.

  Accepts a value or a 1-arity function (applied to the current value).
  Recomputation is deferred — call `recompute/1` to flush:

      socket
      |> Reactive.put(:count, &(&1 + 1))
      |> Reactive.put(:step, 1)
      |> Reactive.recompute()
  """
  def put(socket, field, fun) when is_function(fun, 1) do
    LSocket.put_state(socket, field, fun.(socket.assigns[field]))
  end

  def put(socket, field, value) do
    LSocket.put_state(socket, field, value)
  end

  @doc """
  Recomputes all derived fields affected by dirty state fields, then clears
  the dirty set.

  Returns the socket unchanged if nothing is dirty.
  """
  def recompute(socket) do
    graph = get_graph!(socket)
    dirty = LSocket.dirty(socket)

    if MapSet.size(dirty) == 0 do
      socket
    else
      dirty_list = MapSet.to_list(dirty)

      # Derives transitively affected by dirty state fields
      affected = Graph.affected(graph, dirty_list) |> MapSet.new()

      # Dirty fields that ARE derives (e.g. marked dirty for re-fetch)
      derive_names = MapSet.new(graph.topo_order)
      dirty_derives = MapSet.intersection(dirty, derive_names)
      all_affected = MapSet.union(affected, dirty_derives)

      # Filter topo_order to affected, preserving evaluation order
      to_recompute = Enum.filter(graph.topo_order, &MapSet.member?(all_affected, &1))

      socket = LSocket.clear_dirty(socket)
      run_recompute(socket, graph, to_recompute)
    end
  end

  @doc """
  Recomputes all derived fields in topological order.
  """
  def recompute_all(socket) do
    graph = get_graph!(socket)
    run_recompute(socket, graph, graph.topo_order)
  end

  @doc """
  Recomputes derived fields that depend (transitively) on `changed_field`.
  """
  def recompute_dependents(socket, changed_field) do
    graph = get_graph!(socket)
    to_recompute = Graph.recompute_order(graph, [changed_field])
    run_recompute(socket, graph, to_recompute)
  end

  @doc """
  Returns field names that have the given tag.

  Useful for resource-centric invalidation:

      Reactive.fields_with_tag(graph, {:resource, MyApp.Post})
  """
  def fields_with_tag(%Graph{} = graph, tag) do
    Graph.fields_with_tag(graph, tag)
  end

  @doc """
  Handles async task completion messages.

  Call this from your LiveView's `handle_info/2`:

      def handle_info(msg, socket) do
        case Lavash.Reactive.handle_async(socket, msg) do
          {:ok, socket} -> {:noreply, socket}
          :not_handled -> {:noreply, socket}
        end
      end
  """
  def handle_async(socket, {:lavash_reactive, field, {:ok, result}}) do
    graph = get_graph!(socket)
    socket = LSocket.put_derived(socket, field, AsyncResult.ok(result))
    to_recompute = Graph.recompute_order(graph, [field])
    {:ok, run_recompute(socket, graph, to_recompute)}
  end

  def handle_async(socket, {:lavash_reactive, field, {:error, reason}}) do
    graph = get_graph!(socket)
    failed = AsyncResult.loading() |> AsyncResult.failed({:exit, reason})
    socket = LSocket.put_derived(socket, field, failed)
    to_recompute = Graph.recompute_order(graph, [field])
    {:ok, run_recompute(socket, graph, to_recompute)}
  end

  def handle_async(_socket, _msg), do: :not_handled

  # Retrieve the graph stored on the socket by init/2
  defp get_graph!(socket) do
    LSocket.get(socket, :graph) ||
      raise "Reactive graph not found on socket. Call Reactive.init/2 first."
  end

  # --- Recompute engine ---

  # Recompute derived fields in the given order, handling async and propagation
  defp run_recompute(socket, graph, fields) do
    Enum.reduce(fields, socket, fn field, sock ->
      compute_field(sock, graph, field)
    end)
  end

  defp compute_field(socket, graph, field) do
    dep_values = resolve_deps(socket, graph, field)

    case check_deps(dep_values) do
      {:propagate, async_result} ->
        # A dep is loading or failed — propagate without computing
        LSocket.put_derived(socket, field, async_result)

      {:ready, had_async} ->
        if MapSet.member?(graph.async_fields, field) do
          compute_async(socket, graph, field, dep_values)
        else
          values = unwrap_async_values(dep_values)
          result = graph.compute_fns[field].(values) |> maybe_wrap_changeset()
          final = if had_async, do: AsyncResult.ok(result), else: result
          LSocket.put_derived(socket, field, final)
        end
    end
  end

  # Resolve dependency values, using custom resolvers where registered
  defp resolve_deps(socket, graph, field) do
    resolvers = graph.dep_resolvers

    Map.new(graph.deps[field], fn dep ->
      value =
        case Map.fetch(resolvers, dep) do
          {:ok, resolver_fn} -> resolver_fn.(socket)
          :error -> socket.assigns[dep]
        end

      {dep, value}
    end)
  end

  # Check if any dependency is in a loading or failed state
  defp check_deps(dep_values) do
    Enum.reduce_while(dep_values, {:ready, false}, fn {_key, value}, {_status, had_async} ->
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

  # Spawn a task for an async derive
  defp compute_async(socket, graph, field, dep_values) do
    pid = self()
    values = unwrap_async_values(dep_values)
    compute_fn = graph.compute_fns[field]

    # Component context: route async results via send_update message
    component_id = LSocket.get(socket, :component_id)

    if component_id do
      component_module = socket.assigns[:__component_module__]

      Task.start(fn ->
        try do
          result = compute_fn.(values)
          send(pid, {:lavash_component_async, component_module, component_id, field, result})
        rescue
          e ->
            send(
              pid,
              {:lavash_component_async, component_module, component_id, field, {:error, e}}
            )
        end
      end)
    else
      Task.start(fn ->
        try do
          result = compute_fn.(values)
          send(pid, {:lavash_reactive, field, {:ok, result}})
        rescue
          e -> send(pid, {:lavash_reactive, field, {:error, e}})
        end
      end)
    end

    LSocket.put_derived(socket, field, AsyncResult.loading())
  end

  # Auto-wrap Ash.Changeset results into Lavash.Form for template rendering
  defp maybe_wrap_changeset(%Ash.Changeset{} = changeset), do: Lavash.Form.wrap(changeset)
  defp maybe_wrap_changeset(other), do: other

  # Unwrap AsyncResult.ok values so compute functions receive plain values
  defp unwrap_async_values(dep_values) do
    Map.new(dep_values, fn
      {key, %AsyncResult{ok?: true, result: result}} -> {key, result}
      {key, value} -> {key, value}
    end)
  end

  # Compile an rx() AST into a compute function.
  # The AST uses {:state, [], nil} for @var references (via Macro.var(:state, nil)).
  # We wrap it in `fn state -> <ast> end` and eval once at graph build time.
  defp compile_rx(ast) do
    fn_ast = {:fn, [], [{:->, [], [[{:state, [], nil}], ast]}]}
    {fun, _} = Code.eval_quoted(fn_ast)
    fun
  end

  # Normalize rx deps (which may include {:path, atom, keys} tuples) to plain atoms
  defp normalize_rx_deps(deps) do
    deps
    |> Enum.map(fn
      {:path, name, _keys} -> name
      name when is_atom(name) -> name
    end)
    |> Enum.uniq()
  end
end
