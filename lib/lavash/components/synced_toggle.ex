defmodule Lavash.Components.SyncedToggle do
  @moduledoc """
  Optimistic toggle switch using SyncedVarComponent.

  This component uses SyncedVar for per-field optimistic tracking.
  Unlike ClientComponent which re-renders entire HTML, SyncedVarComponent
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

  use Lavash.SyncedVarComponent
  import Phoenix.Component, only: [sigil_H: 2]

  # Synced field connects to parent state
  synced :value, :boolean

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

  def render(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook={@__hook_name__}
      data-synced-state={@__state_json__}
      data-synced-bindings={@__bindings_json__}
      class="inline-flex items-center gap-2"
    >
      <button
        type="button"
        role="switch"
        aria-checked={to_string(@value)}
        disabled={@disabled}
        data-synced-action="toggle"
        data-synced-field="value"
        data-synced-class="button_class"
        class={@button_class}
      >
        <span
          aria-hidden="true"
          data-synced-class="knob_class"
          class={@knob_class}
        />
      </button>
      <span :if={@label != ""} class="text-sm font-medium text-gray-900">
        {@label}
      </span>
      <span :if={@label == ""} class="text-sm text-gray-500" data-synced-text="display_label">
        {@display_label}
      </span>
    </div>
    """
  end
end
