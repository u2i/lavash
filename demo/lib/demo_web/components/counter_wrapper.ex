defmodule DemoWeb.Components.CounterWrapper do
  @moduledoc """
  A Lavash.Component that wraps CounterControls.

  Demonstrates binding chains:
  LiveView -> CounterWrapper (Lavash.Component) -> CounterControls (ClientComponent)

  The wrapper has its own `count` state which is:
  - Bound to the parent via bind={[count: :parent_field]}
  - Passed to the child via bind={[count: :count]}

  When the child updates count, it propagates up through the wrapper to the LiveView.
  """
  use Lavash.Component

  import Lavash.Component.Helpers, only: [child_component: 1]

  # State that gets bound both upward (to parent) and downward (to child)
  state :count, :integer, from: :ephemeral, default: 0, optimistic: true

  def render(assigns) do
    ~H"""
    <div class="p-4 border border-dashed border-primary/30 rounded-lg bg-primary/5">
      <div class="text-xs text-primary/70 mb-2 font-semibold">
        Lavash.Component Wrapper
      </div>
      <.child_component
        module={DemoWeb.Components.CounterControls}
        id={@id <> "-controls"}
        bind={[count: :count]}
        count={@count}
        myself={@myself}
      />
      <div class="text-xs text-base-content/50 mt-2">
        Internal state: {@count}
      </div>
    </div>
    """
  end
end
