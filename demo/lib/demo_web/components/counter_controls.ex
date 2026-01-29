defmodule DemoWeb.Components.CounterControls do
  @moduledoc """
  A ClientComponent with increment/decrement buttons for a counter.
  Binds its `count` state to the parent's field.
  """
  use Lavash.ClientComponent

  state :count, :integer

  optimistic_action :increment, :count,
    run: fn count, _params -> count + 1 end

  optimistic_action :decrement, :count,
    run: fn count, _params -> max(0, count - 1) end

  render fn assigns ->
    ~L"""
    <div class="flex items-center gap-3">
      <button
        type="button"
        class="btn btn-sm btn-outline"
        data-lavash-action="decrement"
      >
        −
      </button>
      <span class="text-xl font-mono w-12 text-center">{@count || 0}</span>
      <button
        type="button"
        class="btn btn-sm btn-outline"
        data-lavash-action="increment"
      >
        +
      </button>
    </div>
    """
  end
end
