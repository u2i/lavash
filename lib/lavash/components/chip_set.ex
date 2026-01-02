defmodule Lavash.Components.ChipSet do
  @moduledoc """
  A multi-select chip set component with optimistic updates.

  Uses ClientComponent for full client-side re-rendering, enabling instant
  visual feedback when toggling chips.

  ## Usage

      # In parent LiveView:
      state :roast, {:array, :string}, from: :url, default: []

      # In template:
      <.live_component
        module={Lavash.Components.ChipSet}
        id="roast-filter"
        bind={[selected: :roast]}
        selected={@roast}
        values={["light", "medium", "dark"]}
      />

  The component binds its internal `selected` state to the parent's `roast`
  state. When chips are toggled, the update is optimistic - the UI updates
  instantly while the server processes the change.

  ## Styling

  You can customize chip styles via props:

      <.live_component
        module={Lavash.Components.ChipSet}
        id="roast-filter"
        bind={[selected: :roast]}
        selected={@roast}
        values={["light", "medium", "dark"]}
        active_class="bg-blue-600 text-white rounded-full px-3 py-1"
        inactive_class="bg-gray-200 text-gray-700 rounded-full px-3 py-1"
      />
  """

  use Lavash.ClientComponent

  # State connects to parent state
  state :selected, {:array, :string}

  # Props passed from parent
  prop :values, {:list, :string}, required: true
  prop :labels, :map, default: %{}

  # Styling props with defaults
  prop :active_class, :string,
    default: "px-3 py-1.5 text-sm rounded-full border transition-colors cursor-pointer bg-primary text-primary-content border-primary"

  prop :inactive_class, :string,
    default: "px-3 py-1.5 text-sm rounded-full border transition-colors cursor-pointer bg-base-100 text-base-content/70 border-base-300 hover:border-primary/50"

  # Toggle action - adds or removes value from selected array
  optimistic_action :toggle, :selected,
    run: fn selected, value ->
      if value in selected do
        Enum.reject(selected, &(&1 == value))
      else
        selected ++ [value]
      end
    end

  client_template """
  <div class="flex flex-wrap gap-2">
    <button
      :for={value <- @values}
      type="button"
      class={if value in (@selected || []), do: @active_class, else: @inactive_class}
      data-lavash-action="toggle"
      data-lavash-state-field="selected"
      data-lavash-value={value}
    >
      {Map.get(@labels || %{}, value, humanize(value))}
    </button>
  </div>
  """
end
