defmodule Lavash.TestCounterComponent do
  @moduledoc """
  Test fixture: Simple counter component with props and state.
  """
  use Lavash.Component

  prop :initial_count, :integer, default: 0
  prop :step, :integer, default: 1

  state :count, :integer, from: :ephemeral, default: 0

  derive :doubled do
    argument :count, state(:count)
    run fn %{count: c}, _ -> (c || 0) * 2 end
  end

  actions do
    action :increment do
      update :count, fn count ->
        (count || 0) + 1
      end
    end

    action :decrement do
      update :count, &((&1 || 0) - 1)
    end

    action :reset do
      set :count, 0
    end
  end

  # Override mount to set initial count from props
  def mount(socket) do
    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <div id={@id}>
      <span id={"#{@id}-count"}>{@count}</span>
      <span id={"#{@id}-doubled"}>{@doubled}</span>
      <button id={"#{@id}-inc"} phx-click="increment" phx-target={@myself}>+</button>
      <button id={"#{@id}-dec"} phx-click="decrement" phx-target={@myself}>-</button>
      <button id={"#{@id}-reset"} phx-click="reset" phx-target={@myself}>Reset</button>
    </div>
    """
  end
end

defmodule Lavash.TestDerivedPropsComponent do
  @moduledoc """
  Test fixture: Component with derived state from props.
  """
  use Lavash.Component

  prop :value, :integer, required: true
  prop :multiplier, :integer, default: 2

  derive :computed do
    argument :value, prop(:value)
    argument :multiplier, prop(:multiplier)
    run fn %{value: v, multiplier: m}, _ -> v * m end
  end

  def render(assigns) do
    ~H"""
    <div id={@id}>
      <span id={"#{@id}-value"}>{@value}</span>
      <span id={"#{@id}-multiplier"}>{@multiplier}</span>
      <span id={"#{@id}-computed"}>{@computed}</span>
    </div>
    """
  end
end

defmodule Lavash.TestComponentHostLive do
  @moduledoc """
  Test fixture: LiveView that hosts test components.
  """
  use Lavash.LiveView

  state :counter_value, :integer, from: :ephemeral, default: 5

  actions do
    action :set_value, [:value] do
      set :counter_value, &String.to_integer(&1.params.value)
    end
  end

  def render(assigns) do
    ~H"""
    <div>
      <.live_component
        module={Lavash.TestCounterComponent}
        id="counter"
        initial_count={@counter_value}
      />
      <.live_component
        module={Lavash.TestDerivedPropsComponent}
        id="derived"
        value={@counter_value}
      />
      <button id="set-10" phx-click="set_value" phx-value-value="10">Set 10</button>
    </div>
    """
  end
end

defmodule Lavash.TestModalComponent do
  @moduledoc """
  Test fixture: Modal component that tracks render calls.

  Uses a named process to track whether the render function was called,
  allowing tests to verify render is not called when modal is closed.
  """
  use Lavash.Component, extensions: [Lavash.Overlay.Modal.Dsl]

  modal do
    open_field :item_id
  end

  actions do
    action :open, [:id] do
      set :item_id, &(&1.params.id)
    end
  end

  render fn assigns ->
    # Send a message to the test process to track that render was called
    # Uses a registered name so it works across processes
    if test_pid = Process.whereis(:modal_test_pid) do
      send(test_pid, {:modal_rendered, assigns.item_id})
    end

    ~H"""
    <div id="modal-content">
      <h2>Editing item {@item_id}</h2>
      <button phx-click="close" phx-target={@myself}>Close</button>
    </div>
    """
  end
end

defmodule Lavash.TestModalHostLive do
  @moduledoc """
  Test fixture: LiveView that hosts the test modal component.
  """
  use Lavash.LiveView

  actions do
    action :open_modal, [:id] do
      invoke "test-modal", :open,
        module: Lavash.TestModalComponent,
        params: [id: {:param, :id}]
    end
  end

  def render(assigns) do
    ~H"""
    <div>
      <button id="open-modal" phx-click="open_modal" phx-value-id="123">Open Modal</button>
      <.live_component
        module={Lavash.TestModalComponent}
        id="test-modal"
      />
    </div>
    """
  end
end
