defmodule Lavash.Components.SyncedToggle do
  @moduledoc """
  Optimistic toggle switch component.

  ## Usage

      <.lavash_component
        module={Lavash.Components.SyncedToggle}
        id="feature-toggle"
        bind={[value: :enabled]}
        value={@enabled}
        label="Enable feature"
      />
  """
  use Lavash.Component

  state :value, :boolean, from: :ephemeral, default: false

  prop :label, :string, default: ""
  prop :on_label, :string, default: "On"
  prop :off_label, :string, default: "Off"
  prop :disabled, :boolean, default: false

  calculate :display_label, rx(if(@value, do: @on_label, else: @off_label))

  calculate :button_class,
            rx(
              "relative inline-flex h-6 w-11 flex-shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors duration-200 ease-in-out focus:outline-none focus:ring-2 focus:ring-indigo-600 focus:ring-offset-2 " <>
                if(@value, do: "bg-indigo-600", else: "bg-gray-200")
            )

  calculate :knob_class,
            rx(
              "pointer-events-none inline-block h-5 w-5 transform rounded-full bg-white shadow ring-0 transition duration-200 ease-in-out " <>
                if(@value, do: "translate-x-5", else: "translate-x-0")
            )

  actions do
    action :toggle do
      set :value, rx(not @value)
    end
  end

  render fn assigns ->
    ~L"""
    <div class="inline-flex items-center gap-2">
      <button
        type="button"
        role="switch"
        aria-checked={to_string(@value)}
        disabled={@disabled}
        phx-click="toggle"
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
end
