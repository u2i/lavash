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

    test "tags: fields_with_tag returns tagged fields" do
      graph =
        Reactive.new()
        |> Reactive.state(:product_id, nil)
        |> Reactive.state(:customer_id, nil)
        |> Reactive.derive(:product, [:product_id], fn _ -> nil end, tags: [:product_resource])
        |> Reactive.derive(:orders, [:customer_id], fn _ -> [] end, tags: [:order_resource])
        |> Reactive.derive(:total, [:orders], fn _ -> 0 end, tags: [:order_resource])
        |> Reactive.derive(:label, [:product], fn _ -> "" end)
        |> Reactive.build()

      assert Enum.sort(Graph.fields_with_tag(graph, :order_resource)) == [:orders, :total]
      assert Graph.fields_with_tag(graph, :product_resource) == [:product]
      assert Graph.fields_with_tag(graph, :nonexistent) == []
    end

    test "tags: empty by default" do
      graph =
        Reactive.new()
        |> Reactive.state(:x, 0)
        |> Reactive.derive(:a, [:x], &(&1.x + 1))
        |> Reactive.build()

      assert graph.tags == %{}
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

    test "dep_resolver provides custom dep values", %{socket: socket} do
      graph =
        Reactive.new()
        |> Reactive.state(:product_id, nil)
        |> Reactive.dep_resolver(:__actor__, fn socket -> socket.assigns[:current_user] end)
        |> Reactive.derive(:label, [:product_id, :__actor__], fn %{product_id: id, __actor__: actor} ->
          "#{id}-#{actor}"
        end)
        |> Reactive.build()

      socket = Reactive.init(socket, graph)
      socket = Phoenix.Component.assign(socket, :current_user, "tom")
      socket = Reactive.set(socket, graph, :product_id, 42)

      assert socket.assigns.label == "42-tom"
    end
  end

  describe "batch recomputation" do
    setup do
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

    test "put sets state without recomputing derives", %{socket: socket, graph: graph} do
      socket = Reactive.init(socket, graph)
      socket = Reactive.put(socket, graph, :count, 10)

      # State is updated
      assert socket.assigns.count == 10
      # But derives are NOT recomputed yet
      assert socket.assigns.doubled == 0
      assert socket.assigns.quad == 0
    end

    test "recompute_dirty flushes batched changes", %{socket: socket, graph: graph} do
      socket = Reactive.init(socket, graph)

      socket =
        socket
        |> Reactive.put(graph, :count, 10)
        |> Reactive.put(graph, :step, 5)
        |> Reactive.recompute_dirty(graph)

      assert socket.assigns.count == 10
      assert socket.assigns.step == 5
      assert socket.assigns.doubled == 20
      assert socket.assigns.next == 15
      assert socket.assigns.quad == 40
    end

    test "recompute_dirty is a no-op when nothing is dirty", %{socket: socket, graph: graph} do
      socket = Reactive.init(socket, graph)
      # clear dirty from init
      socket = Lavash.Socket.clear_dirty(socket)

      socket2 = Reactive.recompute_dirty(socket, graph)
      assert socket2 == socket
    end

    test "recompute_dirty only recomputes affected derives", %{socket: socket, graph: graph} do
      socket = Reactive.init(socket, graph)

      # Only change :step — should only affect :next, not :doubled or :quad
      socket =
        socket
        |> Reactive.put(graph, :step, 100)
        |> Reactive.recompute_dirty(graph)

      assert socket.assigns.step == 100
      assert socket.assigns.next == 100  # count(0) + step(100)
      assert socket.assigns.doubled == 0  # unchanged
      assert socket.assigns.quad == 0     # unchanged
    end

    test "recompute_all recomputes everything", %{socket: socket, graph: graph} do
      socket = Reactive.init(socket, graph)

      # Manually set a state field via LSocket to bypass recompute
      socket = Phoenix.Component.assign(socket, :count, 7)

      socket = Reactive.recompute_all(socket, graph)

      assert socket.assigns.doubled == 14
      assert socket.assigns.next == 8
      assert socket.assigns.quad == 28
    end

    test "recompute_dependents recomputes downstream of a field", %{socket: socket, graph: graph} do
      socket = Reactive.init(socket, graph)
      socket = Phoenix.Component.assign(socket, :count, 5)

      socket = Reactive.recompute_dependents(socket, graph, :count)

      assert socket.assigns.doubled == 10
      assert socket.assigns.next == 6
      assert socket.assigns.quad == 20
    end

    test "fields_with_tag queries the tag index" do
      graph =
        Reactive.new()
        |> Reactive.state(:id, nil)
        |> Reactive.derive(:product, [:id], fn _ -> nil end, tags: [{:resource, :product}])
        |> Reactive.derive(:orders, [:id], fn _ -> [] end, tags: [{:resource, :order}])
        |> Reactive.build()

      assert Reactive.fields_with_tag(graph, {:resource, :product}) == [:product]
      assert Reactive.fields_with_tag(graph, {:resource, :order}) == [:orders]
      assert Reactive.fields_with_tag(graph, {:resource, :other}) == []
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

  describe "async derives" do
    setup do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}},
        private: %{}
      }

      {:ok, socket: socket}
    end

    test "graph tracks async fields" do
      graph =
        Reactive.new()
        |> Reactive.state(:search, "")
        |> Reactive.derive(:results, [:search], fn _ -> [] end, async: true)
        |> Reactive.derive(:sync_field, [:search], fn %{search: s} -> String.length(s) end)
        |> Reactive.build()

      assert MapSet.member?(graph.async_fields, :results)
      refute MapSet.member?(graph.async_fields, :sync_field)
    end

    test "async derive sets loading on init", %{socket: socket} do
      graph =
        Reactive.new()
        |> Reactive.state(:search, "")
        |> Reactive.derive(:results, [:search], fn _ -> [:a, :b] end, async: true)
        |> Reactive.build()

      socket = Reactive.init(socket, graph)

      assert %Phoenix.LiveView.AsyncResult{loading: true} = socket.assigns.results
    end

    test "async derive sends result message and handle_async resolves it", %{socket: socket} do
      graph =
        Reactive.new()
        |> Reactive.state(:search, "")
        |> Reactive.derive(:results, [:search], fn _ -> [:found] end, async: true)
        |> Reactive.build()

      socket = Reactive.init(socket, graph)

      # Wait for the async task to send its message
      assert_receive {:lavash_reactive, :results, {:ok, [:found]}}, 1000

      {:ok, socket} = Reactive.handle_async(socket, graph, {:lavash_reactive, :results, {:ok, [:found]}})

      assert %Phoenix.LiveView.AsyncResult{ok?: true, result: [:found]} = socket.assigns.results
    end

    test "downstream sync derive propagates loading when async dep is loading", %{socket: socket} do
      graph =
        Reactive.new()
        |> Reactive.state(:search, "")
        |> Reactive.derive(:results, [:search], fn _ -> [:a, :b] end, async: true)
        |> Reactive.derive(:count, [:results], fn %{results: r} -> length(r) end)
        |> Reactive.build()

      socket = Reactive.init(socket, graph)

      # :results is loading, so :count should propagate loading
      assert %Phoenix.LiveView.AsyncResult{loading: true} = socket.assigns.results
      assert %Phoenix.LiveView.AsyncResult{loading: true} = socket.assigns.count
    end

    test "downstream sync derive computes after async resolves", %{socket: socket} do
      graph =
        Reactive.new()
        |> Reactive.state(:search, "")
        |> Reactive.derive(:results, [:search], fn _ -> [:a, :b, :c] end, async: true)
        |> Reactive.derive(:count, [:results], fn %{results: r} -> length(r) end)
        |> Reactive.build()

      socket = Reactive.init(socket, graph)

      # Wait for task and handle the message
      assert_receive {:lavash_reactive, :results, {:ok, [:a, :b, :c]}}, 1000
      {:ok, socket} = Reactive.handle_async(socket, graph, {:lavash_reactive, :results, {:ok, [:a, :b, :c]}})

      # :results resolved, :count should compute with unwrapped value
      assert %Phoenix.LiveView.AsyncResult{ok?: true, result: [:a, :b, :c]} = socket.assigns.results
      # :count wraps in AsyncResult.ok since its dep was async
      assert %Phoenix.LiveView.AsyncResult{ok?: true, result: 3} = socket.assigns.count
    end

    test "error propagation through async chain", %{socket: socket} do
      graph =
        Reactive.new()
        |> Reactive.state(:x, 0)
        |> Reactive.derive(:fetched, [:x], fn _ -> raise "boom" end, async: true)
        |> Reactive.derive(:downstream, [:fetched], fn %{fetched: f} -> f + 1 end)
        |> Reactive.build()

      socket = Reactive.init(socket, graph)

      # Wait for the error
      assert_receive {:lavash_reactive, :fetched, {:error, %RuntimeError{message: "boom"}}}, 1000

      {:ok, socket} =
        Reactive.handle_async(socket, graph, {:lavash_reactive, :fetched, {:error, %RuntimeError{message: "boom"}}})

      # :fetched is failed (wrapped as {:exit, reason} per Phoenix convention)
      assert %Phoenix.LiveView.AsyncResult{failed: {:exit, %RuntimeError{message: "boom"}}} = socket.assigns.fetched
      # :downstream propagates the failed state
      assert %Phoenix.LiveView.AsyncResult{failed: {:exit, %RuntimeError{message: "boom"}}} = socket.assigns.downstream
    end

    test "state change re-triggers async derive", %{socket: socket} do
      graph =
        Reactive.new()
        |> Reactive.state(:search, "")
        |> Reactive.derive(:results, [:search], fn %{search: s} -> [s, s] end, async: true)
        |> Reactive.build()

      socket = Reactive.init(socket, graph)

      # Drain the first task
      assert_receive {:lavash_reactive, :results, {:ok, ["", ""]}}, 1000
      {:ok, socket} = Reactive.handle_async(socket, graph, {:lavash_reactive, :results, {:ok, ["", ""]}})
      assert %Phoenix.LiveView.AsyncResult{ok?: true, result: ["", ""]} = socket.assigns.results

      # Change state — should re-trigger the async derive
      socket = Reactive.set(socket, graph, :search, "hello")
      assert %Phoenix.LiveView.AsyncResult{loading: true} = socket.assigns.results

      # New task completes
      assert_receive {:lavash_reactive, :results, {:ok, ["hello", "hello"]}}, 1000
      {:ok, socket} = Reactive.handle_async(socket, graph, {:lavash_reactive, :results, {:ok, ["hello", "hello"]}})
      assert %Phoenix.LiveView.AsyncResult{ok?: true, result: ["hello", "hello"]} = socket.assigns.results
    end

    test "handle_async returns :not_handled for unrelated messages", %{socket: socket} do
      graph =
        Reactive.new()
        |> Reactive.state(:x, 0)
        |> Reactive.build()

      socket = Reactive.init(socket, graph)
      assert :not_handled = Reactive.handle_async(socket, graph, {:something_else, :data})
    end
  end
end
