defmodule DemoWeb.Components.CounterControls do
  @moduledoc """
  A component with increment/decrement buttons for a counter.
  Binds its `count` state to the parent's field.
  """
  use Lavash.Component

  state :count, :integer, from: :ephemeral, default: 0, optimistic: true

  actions do
    action :increment do
      set :count, rx(@count + 1)
    end

    action :decrement do
      set :count, rx(if @count > 0, do: @count - 1, else: 0)
    end
  end

  template do
    ~H"""
    <div class="flex items-center gap-3">
      <button
        type="button"
        class="btn btn-sm btn-outline"
        phx-click="decrement"
      >
        −
      </button>
      <span class="text-xl font-mono w-12 text-center">{@count}</span>
      <button
        type="button"
        class="btn btn-sm btn-outline"
        phx-click="increment"
      >
        +
      </button>
    </div>
    """
  end
end
