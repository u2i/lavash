defmodule Lavash.Components.SyncedToggle do
  @moduledoc """
  Optimistic toggle switch using LiveComponent.

  This component uses SyncedVar for per-field optimistic tracking.
  Unlike ClientComponent which re-renders entire HTML, LiveComponent
  updates individual values in a static DOM structure via data-synced-* attributes.

  ## Usage

      <.live_component
        module={Lavash.Components.SyncedToggle}
        id="feature-toggle"
        bind={[value: :enabled]}
        value={@enabled}
        label="Enable feature"
      />

  ## How it works

  1. User clicks toggle -> client instantly updates via SyncedVar.setOptimistic()
  2. Server receives event and updates state
  3. SyncedVar.serverSet() only accepts if no pending updates (version match)
  """

  use Lavash.LiveComponent

  # State connects to parent state
  state :value, :boolean

  # Props from parent (read-only)
  prop :label, :string, default: ""
  prop :on_label, :string, default: "On"
  prop :off_label, :string, default: "Off"
  prop :disabled, :boolean, default: false

  # Calculate display label based on value
  calculate :display_label, if(@value, do: @on_label, else: @off_label)

  # Calculate full CSS class strings for client-side updates
  calculate :button_class,
    "relative inline-flex h-6 w-11 flex-shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors duration-200 ease-in-out focus:outline-none focus:ring-2 focus:ring-indigo-600 focus:ring-offset-2 " <>
    if(@value, do: "bg-indigo-600", else: "bg-gray-200")

  calculate :knob_class,
    "pointer-events-none inline-block h-5 w-5 transform rounded-full bg-white shadow ring-0 transition duration-200 ease-in-out " <>
    if(@value, do: "translate-x-5", else: "translate-x-0")

  # Optimistic action - toggle inverts the value
  optimistic_action :toggle, :value,
    run: fn value, _arg -> !value end

  # Template with natural syntax - l-action and class={@calc} are auto-transformed
  client_template """
  <div class="inline-flex items-center gap-2">
    <button
      type="button"
      role="switch"
      aria-checked={to_string(@value)}
      disabled={@disabled}
      l-action="toggle"
      class={@button_class}
    >
      <span
        aria-hidden="true"
        class={@knob_class}
      />
    </button>
    <span :if={@label != ""} class="text-sm font-medium text-gray-900">
      {@label}
    </span>
    <span :if={@label == ""} class="text-sm text-gray-500">
      {@display_label}
    </span>
  </div>
  """
end
