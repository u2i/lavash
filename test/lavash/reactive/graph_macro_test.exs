defmodule Lavash.Reactive.GraphMacroTest do
  use ExUnit.Case, async: true

  import Lavash.Rx
  import Lavash.Reactive.GraphMacro

  alias Lavash.Reactive

  defmodule Counter do
    import Lavash.Rx
    import Lavash.Reactive.GraphMacro

    defgraph do
      state :count, 0
      state :step, 1
      derive :doubled, rx(@count * @step)
      derive :quad, rx(@doubled * 2)
    end
  end

  defmodule WithAsync do
    import Lavash.Rx
    import Lavash.Reactive.GraphMacro

    defgraph do
      state :query, ""
      derive(:results, rx(String.upcase(@query)), async: true)
      derive :count, rx(length(@results))
    end
  end

  describe "defgraph" do
    test "generates __reactive_graph__/0 that returns a valid graph" do
      graph = Counter.__reactive_graph__()
      assert %Lavash.Rx.Graph{} = graph
      assert Map.has_key?(graph.state_defaults, :count)
      assert Map.has_key?(graph.state_defaults, :step)
      assert :doubled in graph.topo_order
      assert :quad in graph.topo_order
    end

    test "graph computes derives correctly via Reactive" do
      graph = Counter.__reactive_graph__()
      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}, private: %{}}
      socket = Reactive.init(socket, graph)

      assert socket.assigns[:count] == 0
      assert socket.assigns[:step] == 1
      assert socket.assigns[:doubled] == 0
      assert socket.assigns[:quad] == 0

      socket = socket |> Reactive.put(:count, 5) |> Reactive.recompute()
      assert socket.assigns[:doubled] == 5
      assert socket.assigns[:quad] == 10

      socket = socket |> Reactive.put(:step, 3) |> Reactive.recompute()
      assert socket.assigns[:doubled] == 15
      assert socket.assigns[:quad] == 30
    end

    test "graph is cached in persistent_term" do
      graph1 = Counter.__reactive_graph__()
      graph2 = Counter.__reactive_graph__()
      assert graph1 === graph2
    end

    test "async derives are included in graph" do
      graph = WithAsync.__reactive_graph__()
      assert :results in graph.topo_order
      assert :count in graph.topo_order
      assert MapSet.member?(graph.async_fields, :results)
    end
  end
end
