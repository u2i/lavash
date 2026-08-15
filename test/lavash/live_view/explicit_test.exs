defmodule Lavash.LiveView.ExplicitTest do
  use ExUnit.Case, async: false

  defmodule Sample do
    use Lavash.LiveView.Explicit

    reactive do
      state :count, 0
      state :step, 1
      derive :doubled, rx(@count * @step)
    end

    @impl Phoenix.LiveView
    def render(assigns) do
      ~H"""
      <p>{@count}</p>
      """
    end
  end

  defmodule OverridesMount do
    use Lavash.LiveView.Explicit

    reactive do
      state :count, 0
      derive :doubled, rx(@count * 2)
    end

    # The documented override pattern: super does the lavash init.
    # Regression: the default mount used to be injected in
    # @before_compile (i.e. AFTER user code), so `super` didn't exist.
    @impl Phoenix.LiveView
    def mount(params, session, socket) do
      {:ok, socket} = super(params, session, socket)
      {:ok, Phoenix.Component.assign(socket, :extra, :from_override)}
    end

    @impl Phoenix.LiveView
    def render(assigns) do
      ~H"""
      <p>{@count}</p>
      """
    end
  end

  setup do
    on_exit(fn ->
      :persistent_term.erase({Lavash.Reactive, Sample})
      :persistent_term.erase({Lavash.Rx.Cache, Sample})
      :persistent_term.erase({Lavash.Reactive, OverridesMount})
      :persistent_term.erase({Lavash.Rx.Cache, OverridesMount})
    end)

    :ok
  end

  test "a user-defined mount/3 can call super for the lavash init" do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}},
      private: %{}
    }

    {:ok, socket} = OverridesMount.mount(%{}, %{}, socket)

    assert socket.assigns.count == 0
    assert socket.assigns.doubled == 0
    assert socket.assigns.extra == :from_override
  end

  test "exposes a cached __lavash_reactive_graph__/0" do
    graph = Sample.__lavash_reactive_graph__()
    assert is_struct(graph, Lavash.Rx.Graph)

    # Called twice — same instance (cached).
    assert :erlang.phash2(graph) == :erlang.phash2(Sample.__lavash_reactive_graph__())
  end

  test "mount/3 initializes the socket with the reactive graph and state defaults" do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}},
      private: %{}
    }

    {:ok, socket} = Sample.mount(%{}, %{}, socket)

    # Reactive engine has stored the graph in private and computed defaults.
    assert socket.assigns.count == 0
    assert socket.assigns.step == 1
    assert socket.assigns.doubled == 0
  end

  test "put_state/3 mutates a field and recomputes derives in one call" do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}},
      private: %{}
    }

    {:ok, socket} = Sample.mount(%{}, %{}, socket)

    import Lavash.LiveView.Explicit, only: [put_state: 3]

    socket = put_state(socket, :count, 5)
    assert socket.assigns.count == 5
    # doubled = count * step = 5 * 1 = 5
    assert socket.assigns.doubled == 5

    # 1-arity function form
    socket = put_state(socket, :count, &(&1 + 10))
    assert socket.assigns.count == 15
    assert socket.assigns.doubled == 15
  end

  test "compile error on a bad statement inside reactive do" do
    assert_raise CompileError, ~r/unexpected statement/, fn ->
      defmodule BadStatement do
        use Lavash.LiveView.Explicit

        reactive do
          state :count, 0
          # not a known statement
          nonsense(:foo, :bar)
        end
      end
    end
  end
end
