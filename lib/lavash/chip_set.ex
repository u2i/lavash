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
  use Lavash.Component

  state :selected, {:array, :string}, from: :ephemeral, default: []

  prop :values, :any, required: true
  prop :labels, :any, default: %{}
  prop :active_class, :any,
    default: "px-3 py-1.5 rounded-full text-sm font-medium border transition-colors bg-primary text-primary-content border-primary"
  prop :inactive_class, :any,
    default: "px-3 py-1.5 rounded-full text-sm font-medium border transition-colors bg-base-100 text-base-content/70 border-base-300 hover:bg-base-200"

  actions do
    action :toggle, [:val] do
      set :selected, rx(
        if @val in @selected,
          do: Enum.reject(@selected, &(&1 == @val)),
          else: @selected ++ [@val]
      )
    end
  end

  render fn assigns ->
    ~L"""
    <div class="flex flex-wrap gap-2">
      <button
        :for={value <- @values}
        type="button"
        class={if value in (@selected || []), do: @active_class, else: @inactive_class}
        data-lavash-member={"selected|#{@active_class}|#{@inactive_class}"}
        phx-click="toggle"
        phx-value-val={value}
      >
        {Map.get(@labels || %{}, value, humanize(value))}
      </button>
    </div>
    """
  end

  defp humanize(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
