defmodule Lavash.ChipSet do
  @moduledoc """
  A self-contained chip set component for multi-select filtering.

  Renders toggle buttons where each value can be selected/deselected.
  Handles optimistic updates internally — parent just binds a list.

  ## Usage

      <.lavash_component
        module={Lavash.ChipSet}
        id="roast-chips"
        values={["light", "medium", "dark"]}
        selected={@roast}
        bind={[selected: :roast]}
      />

  ## With custom labels

      <.lavash_component
        module={Lavash.ChipSet}
        id="roast-chips"
        values={["light", "medium", "medium_dark", "dark"]}
        labels={%{"medium_dark" => "Med-Dark"}}
        selected={@roast}
        bind={[selected: :roast]}
      />

  ## Styling

  Default chip classes use DaisyUI. Override with:
  - `active_class` — class when chip is selected
  - `inactive_class` — class when chip is not selected
  """
  use Lavash.ClientComponent

  state :selected, {:array, :string}

  prop :values, :any, required: true
  prop :labels, :any, default: %{}
  prop :active_class, :any,
    default: "px-3 py-1.5 rounded-full text-sm font-medium border transition-colors bg-primary text-primary-content border-primary"
  prop :inactive_class, :any,
    default: "px-3 py-1.5 rounded-full text-sm font-medium border transition-colors bg-base-100 text-base-content/70 border-base-300 hover:bg-base-200"

  optimistic_action :toggle, :selected,
    run: fn selected, val ->
      if val in selected, do: selected -- [val], else: selected ++ [val]
    end

  render fn assigns ->
    ~L"""
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
end
