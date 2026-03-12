defmodule Lavash.ReactiveTest do
  use ExUnit.Case, async: true

  alias Lavash.Reactive
  alias Lavash.Reactive.Graph

  describe "builder" do
    test "new returns empty builder" do
      builder = Reactive.new()
      assert %Reactive{states: [], derives: []} = builder
    end

    test "state accumulates declarations" do
      builder =
        Reactive.new()
        |> Reactive.state(:count, 0)
        |> Reactive.state(:step, 1)

      assert length(builder.states) == 2
    end

    test "derive accumulates declarations" do
      builder =
        Reactive.new()
        |> Reactive.state(:count, 0)
        |> Reactive.derive(:doubled, [:count], &(&1.count * 2))

      assert length(builder.derives) == 1
    end

    test "build produces a Graph struct" do
      graph =
        Reactive.new()
        |> Reactive.state(:count, 0)
        |> Reactive.derive(:doubled, [:count], &(&1.count * 2))
        |> Reactive.build()

      assert %Graph{} = graph
      assert graph.state_defaults == %{count: 0}
      assert graph.deps == %{doubled: [:count]}
      assert graph.topo_order == [:doubled]
      assert %{count: [:doubled]} = graph.dependents
    end
  end

  describe "graph compilation" do
    test "topo sort with chain: a -> b -> c" do
      graph =
        Reactive.new()
        |> Reactive.state(:x, 1)
        |> Reactive.derive(:a, [:x], &(&1.x + 1))
        |> Reactive.derive(:b, [:a], &(&1.a + 1))
        |> Reactive.derive(:c, [:b], &(&1.b + 1))
        |> Reactive.build()

      assert graph.topo_order == [:a, :b, :c]
    end

    test "topo sort with diamond: x -> a,b -> c" do
      graph =
        Reactive.new()
        |> Reactive.state(:x, 1)
        |> Reactive.derive(:a, [:x], &(&1.x + 1))
        |> Reactive.derive(:b, [:x], &(&1.x * 2))
        |> Reactive.derive(:c, [:a, :b], &(&1.a + &1.b))
        |> Reactive.build()

      # a and b before c; a and b order relative to each other doesn't matter
      c_idx = Enum.find_index(graph.topo_order, &(&1 == :c))
      a_idx = Enum.find_index(graph.topo_order, &(&1 == :a))
      b_idx = Enum.find_index(graph.topo_order, &(&1 == :b))

      assert a_idx < c_idx
      assert b_idx < c_idx
    end

    test "affected fields for a dirty state" do
      graph =
        Reactive.new()
        |> Reactive.state(:x, 0)
        |> Reactive.state(:y, 0)
        |> Reactive.derive(:a, [:x], &(&1.x + 1))
        |> Reactive.derive(:b, [:a], &(&1.a * 2))
        |> Reactive.derive(:c, [:y], &(&1.y - 1))
        |> Reactive.build()

      # Changing :x affects :a and :b (transitively), not :c
      affected = Graph.affected(graph, [:x])
      assert :a in affected
      assert :b in affected
      refute :c in affected

      # Changing :y only affects :c
      assert Graph.affected(graph, [:y]) == [:c]
    end

    test "recompute_order preserves topo order" do
      graph =
        Reactive.new()
        |> Reactive.state(:x, 0)
        |> Reactive.derive(:a, [:x], &(&1.x + 1))
        |> Reactive.derive(:b, [:a], &(&1.a * 2))
        |> Reactive.derive(:c, [:x], &(&1.x - 1))
        |> Reactive.build()

      order = Graph.recompute_order(graph, [:x])
      a_idx = Enum.find_index(order, &(&1 == :a))
      b_idx = Enum.find_index(order, &(&1 == :b))
      assert a_idx < b_idx
    end
  end

  describe "runtime (socket integration)" do
    setup do
      # Build a minimal Phoenix socket for testing
      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}},
        private: %{}
      }

      graph =
        Reactive.new()
        |> Reactive.state(:count, 0)
        |> Reactive.state(:step, 1)
        |> Reactive.derive(:doubled, [:count], &(&1.count * 2))
        |> Reactive.derive(:next, [:count, :step], &(&1.count + &1.step))
        |> Reactive.derive(:quad, [:doubled], &(&1.doubled * 2))
        |> Reactive.build()

      {:ok, socket: socket, graph: graph}
    end

    test "init sets state defaults and computes derived", %{socket: socket, graph: graph} do
      socket = Reactive.init(socket, graph)

      assert socket.assigns.count == 0
      assert socket.assigns.step == 1
      assert socket.assigns.doubled == 0
      assert socket.assigns.next == 1
      assert socket.assigns.quad == 0
    end

    test "set updates state and recomputes dependents", %{socket: socket, graph: graph} do
      socket = Reactive.init(socket, graph)
      socket = Reactive.set(socket, graph, :count, 5)

      assert socket.assigns.count == 5
      assert socket.assigns.doubled == 10
      assert socket.assigns.next == 6
      assert socket.assigns.quad == 20
    end

    test "set only recomputes affected fields", %{socket: socket, graph: graph} do
      socket = Reactive.init(socket, graph)
      socket = Reactive.set(socket, graph, :step, 3)

      # :step only affects :next, not :doubled or :quad
      assert socket.assigns.step == 3
      assert socket.assigns.next == 3  # count(0) + step(3)
      assert socket.assigns.doubled == 0  # unchanged
      assert socket.assigns.quad == 0  # unchanged
    end

    test "update applies function and recomputes", %{socket: socket, graph: graph} do
      socket = Reactive.init(socket, graph)
      socket = Reactive.set(socket, graph, :count, 3)
      socket = Reactive.update(socket, graph, :count, &(&1 + 1))

      assert socket.assigns.count == 4
      assert socket.assigns.doubled == 8
      assert socket.assigns.quad == 16
    end

    test "multiple sets compose correctly", %{socket: socket, graph: graph} do
      socket = Reactive.init(socket, graph)

      socket =
        socket
        |> Reactive.set(graph, :count, 10)
        |> Reactive.set(graph, :step, 5)

      assert socket.assigns.count == 10
      assert socket.assigns.step == 5
      assert socket.assigns.doubled == 20
      assert socket.assigns.next == 15
      assert socket.assigns.quad == 40
    end
  end

  describe "cached graph via persistent_term" do
    defmodule TestLive do
      def graph do
        Lavash.Reactive.graph(__MODULE__, fn ->
          Lavash.Reactive.new()
          |> Lavash.Reactive.state(:count, 0)
          |> Lavash.Reactive.state(:step, 1)
          |> Lavash.Reactive.derive(:doubled, [:count], fn %{count: c} -> c * 2 end)
          |> Lavash.Reactive.derive(:next, [:count, :step], fn %{count: c, step: s} -> c + s end)
          |> Lavash.Reactive.build()
        end)
      end
    end

    test "graph is cached and returns a valid Graph struct" do
      graph = TestLive.graph()
      assert %Graph{} = graph
      assert graph.state_defaults == %{count: 0, step: 1}
      assert Enum.sort(graph.topo_order) == [:doubled, :next]

      # Second call returns same cached instance
      assert TestLive.graph() == graph
    end

    test "cached graph works with runtime functions" do
      graph = TestLive.graph()

      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}},
        private: %{}
      }

      socket = Reactive.init(socket, graph)
      assert socket.assigns.doubled == 0
      assert socket.assigns.next == 1

      socket = Reactive.set(socket, graph, :count, 7)
      assert socket.assigns.doubled == 14
      assert socket.assigns.next == 8
    end
  end
end
