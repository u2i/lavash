defmodule Lavash.Components.Toggle do
  @moduledoc """
  Optimistic toggle switch using SyncedVar.

  Unlike ClientComponent which re-renders entire HTML, SyncedVarComponent
  updates individual values in a static DOM structure. This is more efficient
  for simple value changes but cannot handle structural changes.

  ## Usage

      <.live_component
        module={Lavash.Components.Toggle}
        id="feature-toggle"
        bind={[value: :enabled]}
        value={@enabled}
        label="Enable feature"
      />

  ## How it works

  1. User clicks toggle -> client instantly updates UI via SyncedVar
  2. Server receives event and updates state
  3. Stale server patches are rejected if client has pending updates
  """

  use Lavash.ClientComponent

  bind :value, :boolean

  prop :label, :string, default: ""
  prop :on_label, :string, default: "On"
  prop :off_label, :string, default: "Off"
  prop :disabled, :boolean, default: false

  # Calculate display label based on value
  calculate :display_label, if(@value, do: @on_label, else: @off_label)

  # Calculate CSS classes
  calculate :button_bg, if(@value, do: "bg-indigo-600", else: "bg-gray-200")
  calculate :knob_position, if(@value, do: "translate-x-5", else: "translate-x-0")

  optimistic_action :toggle, :value,
    run: fn value, _arg -> !value end

  client_template """
  <div class="inline-flex items-center gap-2">
    <button
      type="button"
      role="switch"
      aria-checked={if @value, do: "true", else: "false"}
      disabled={@disabled}
      data-optimistic="toggle"
      data-optimistic-field="value"
      data-optimistic-value="toggle"
      class={"relative inline-flex h-6 w-11 flex-shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors duration-200 ease-in-out focus:outline-none focus:ring-2 focus:ring-indigo-600 focus:ring-offset-2 " <> @button_bg <> if(@disabled, do: " opacity-50 cursor-not-allowed", else: "")}
    >
      <span
        aria-hidden="true"
        class={"pointer-events-none inline-block h-5 w-5 transform rounded-full bg-white shadow ring-0 transition duration-200 ease-in-out " <> @knob_position}
      />
    </button>
    <span :if={@label != ""} class="text-sm font-medium text-gray-900">
      {@label}
    </span>
    <span :if={@label == ""} class="text-sm text-gray-500" data-optimistic-display="display_label">
      {@display_label}
    </span>
  </div>
  """
end
