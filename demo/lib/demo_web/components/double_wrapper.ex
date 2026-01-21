defmodule DemoWeb.Components.DoubleWrapper do
  @moduledoc """
  A Lavash.Component that wraps CounterWrapper to test 3-level nesting.

  Demonstrates deep binding chains:
  LiveView -> DoubleWrapper -> CounterWrapper -> CounterControls

  Each level has its own state that gets bound both up and down.
  Updates propagate through the full chain.
  """
  use Lavash.Component

  import Lavash.Component.Helpers, only: [child_component: 1]

  # State that gets bound both upward (to parent) and downward (to CounterWrapper)
  state :count, :integer, from: :ephemeral, default: 0, optimistic: true

  def render(assigns) do
    ~H"""
    <div class="p-4 border-2 border-dashed border-secondary/30 rounded-lg bg-secondary/5">
      <div class="text-xs text-secondary/70 mb-2 font-semibold">
        Double Wrapper (Level 2)
      </div>
      <.child_component
        module={DemoWeb.Components.CounterWrapper}
        id={@id <> "-inner"}
        bind={[count: :count]}
        count={@count}
        myself={@myself}
      />
      <div class="text-xs text-base-content/50 mt-2">
        Level 2 state: {@count}
      </div>
    </div>
    """
  end
end
