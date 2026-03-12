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
      end

  `graph/2` builds the graph on first call and caches it in `persistent_term`,
  so the topo sort only runs once per module for the entire app lifecycle.

  Note: anonymous functions cannot be stored in module attributes (`@graph`)
  due to BEAM escaping limitations. The `graph/2` + `persistent_term` approach
  achieves the same zero-cost-after-first-call behavior without macros.
  """

  alias Lavash.Reactive.Graph
  alias Lavash.Socket, as: LSocket

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
  """
  def derive(%__MODULE__{} = builder, name, deps, fun) do
    %{builder | derives: [{name, deps, fun} | builder.derives]}
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

  # Recompute derived fields in the given order
  defp recompute(socket, graph, fields) do
    Enum.reduce(fields, socket, fn field, sock ->
      dep_values = Map.take(sock.assigns, graph.deps[field])
      result = graph.compute_fns[field].(dep_values)
      LSocket.put_derived(sock, field, result)
    end)
  end
end
