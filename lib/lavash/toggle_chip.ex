defmodule Lavash.ToggleChip do
  @moduledoc """
  A self-contained toggle chip component for boolean state.

  Renders a single button that toggles between active/inactive.
  Handles optimistic updates internally — parent just binds a boolean.

  ## Usage

      <.lavash_component
        module={Lavash.ToggleChip}
        id="in-stock-toggle"
        label="In Stock Only"
        active={@in_stock}
        bind={[active: :in_stock]}
      />

  ## Styling

  Override with `active_class` and `inactive_class` props.
  """
  use Lavash.Component

  state :active, :boolean, from: :ephemeral, default: false

  prop :label, :string, default: "Toggle"
  prop :active_class, :any,
    default: "px-3 py-1.5 rounded-full text-sm font-medium border transition-colors bg-primary text-primary-content border-primary"
  prop :inactive_class, :any,
    default: "px-3 py-1.5 rounded-full text-sm font-medium border transition-colors bg-base-100 text-base-content/70 border-base-300 hover:bg-base-200"

  actions do
    action :toggle do
      set :active, rx(not @active)
    end
  end

  render fn assigns ->
    ~L"""
    <button
      type="button"
      class={if @active, do: @active_class, else: @inactive_class}
      phx-click="toggle"
    >
      {@label}
    </button>
    """
  end
end
