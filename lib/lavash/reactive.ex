defmodule Lavash.Reactive do
  @moduledoc """
  Reactive state management for Phoenix LiveViews.

  Provides a builder API to define state fields and derived computations,
  producing a precomputed `%Graph{}` that drives automatic recomputation
  when state changes.

  ## Usage

      defmodule MyLive do
        use Phoenix.LiveView

        defp graph do
          Lavash.Reactive.graph(__MODULE__, fn ->
            Lavash.Reactive.new()
            |> Lavash.Reactive.state(:count, 0)
            |> Lavash.Reactive.state(:step, 1)
            |> Lavash.Reactive.derive(:doubled, [:count], &(&1.count * 2))
            |> Lavash.Reactive.derive(:next, [:count, :step], &(&1.count + &1.step))
            |> Lavash.Reactive.build()
          end)
        end

        def mount(_params, _session, socket) do
          {:ok, Lavash.Reactive.init(socket, graph())}
        end

        def handle_event("inc", _, socket) do
          {:noreply, Lavash.Reactive.set(socket, graph(), :count, socket.assigns.count + 1)}
        end

        # Required for async derives:
        def handle_info(msg, socket) do
          case Lavash.Reactive.handle_async(socket, graph(), msg) do
            {:ok, socket} -> {:noreply, socket}
            :not_handled -> {:noreply, socket}
          end
        end
      end

  ## Async Derives

  Mark a derive as `async: true` to run its computation in a background task.
  The field is immediately set to `AsyncResult.loading()`, then updated when
  the task completes. Downstream derives automatically propagate loading and
  failed states.

      |> Reactive.derive(:results, [:search], &fetch_results/1, async: true)
      |> Reactive.derive(:count, [:results], fn %{results: r} -> length(r) end)

  `graph/2` builds the graph on first call and caches it in `persistent_term`,
  so the topo sort only runs once per module for the entire app lifecycle.

  Note: anonymous functions cannot be stored in module attributes (`@graph`)
  due to BEAM escaping limitations. The `graph/2` + `persistent_term` approach
  achieves the same zero-cost-after-first-call behavior without macros.
  """

  alias Lavash.Reactive.Graph
  alias Lavash.Socket, as: LSocket
  alias Phoenix.LiveView.AsyncResult

  # Builder struct — accumulates state/derive declarations before build()
  defstruct states: [], derives: []

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
  Registers a derived field with dependencies and a compute function.

  The compute function receives a map of dependency values:

      derive(builder, :doubled, [:count], fn %{count: c} -> c * 2 end)

  Options:
    - `async: true` — computation runs in a background task. The field
      is set to `AsyncResult.loading()` immediately, then updated when
      the task completes. Downstream derives propagate loading/failed
      states automatically.
  """
  def derive(%__MODULE__{} = builder, name, deps, fun, opts \\ []) do
    async = Keyword.get(opts, :async, false)
    %{builder | derives: [{name, deps, fun, async} | builder.derives]}
  end

  @doc """
  Finalizes the builder into a frozen `%Graph{}`.

  Performs topological sort and builds dependency indices.
  After this, the graph is immutable and ready for runtime use.
  """
  def build(%__MODULE__{} = builder) do
    Graph.compile(Enum.reverse(builder.states), Enum.reverse(builder.derives))
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

  # --- Runtime functions (operate on socket + graph) ---

  @doc """
  Initializes a socket with the reactive graph.

  Sets all state defaults and computes all derived values.
  """
  def init(socket, %Graph{} = graph) do
    socket = LSocket.init(socket)

    # Set state defaults
    socket =
      Enum.reduce(graph.state_defaults, socket, fn {name, default}, sock ->
        LSocket.put_state(sock, name, default)
      end)

    # Compute all derived values in topo order
    recompute(socket, graph, graph.topo_order)
  end

  @doc """
  Sets a state field and recomputes affected derived fields.
  """
  def set(socket, %Graph{} = graph, field, value) do
    socket = LSocket.put_state(socket, field, value)
    to_recompute = Graph.recompute_order(graph, [field])
    recompute(socket, graph, to_recompute)
  end

  @doc """
  Updates a state field via function and recomputes affected derived fields.
  """
  def update(socket, %Graph{} = graph, field, fun) do
    set(socket, graph, field, fun.(socket.assigns[field]))
  end

  @doc """
  Handles async task completion messages.

  Call this from your LiveView's `handle_info/2`:

      def handle_info(msg, socket) do
        case Lavash.Reactive.handle_async(socket, graph(), msg) do
          {:ok, socket} -> {:noreply, socket}
          :not_handled -> {:noreply, socket}
        end
      end
  """
  def handle_async(socket, %Graph{} = graph, {:lavash_reactive, field, {:ok, result}}) do
    socket = LSocket.put_derived(socket, field, AsyncResult.ok(result))
    to_recompute = Graph.recompute_order(graph, [field])
    {:ok, recompute(socket, graph, to_recompute)}
  end

  def handle_async(socket, %Graph{} = graph, {:lavash_reactive, field, {:error, reason}}) do
    failed = AsyncResult.loading() |> AsyncResult.failed({:exit, reason})
    socket = LSocket.put_derived(socket, field, failed)
    to_recompute = Graph.recompute_order(graph, [field])
    {:ok, recompute(socket, graph, to_recompute)}
  end

  def handle_async(_socket, _graph, _msg), do: :not_handled

  # --- Recompute engine ---

  # Recompute derived fields in the given order, handling async and propagation
  defp recompute(socket, graph, fields) do
    Enum.reduce(fields, socket, fn field, sock ->
      compute_field(sock, graph, field)
    end)
  end

  defp compute_field(socket, graph, field) do
    dep_values = Map.take(socket.assigns, graph.deps[field])

    case check_deps(dep_values) do
      {:propagate, async_result} ->
        # A dep is loading or failed — propagate without computing
        LSocket.put_derived(socket, field, async_result)

      {:ready, had_async} ->
        if MapSet.member?(graph.async_fields, field) do
          compute_async(socket, graph, field, dep_values)
        else
          values = unwrap_async_values(dep_values)
          result = graph.compute_fns[field].(values)
          final = if had_async, do: AsyncResult.ok(result), else: result
          LSocket.put_derived(socket, field, final)
        end
    end
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

    Task.start(fn ->
      try do
        result = compute_fn.(values)
        send(pid, {:lavash_reactive, field, {:ok, result}})
      rescue
        e -> send(pid, {:lavash_reactive, field, {:error, e}})
      end
    end)

    LSocket.put_derived(socket, field, AsyncResult.loading())
  end

  # Unwrap AsyncResult.ok values so compute functions receive plain values
  defp unwrap_async_values(dep_values) do
    Map.new(dep_values, fn
      {key, %AsyncResult{ok?: true, result: result}} -> {key, result}
      {key, value} -> {key, value}
    end)
  end
end
