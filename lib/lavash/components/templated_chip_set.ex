defmodule Lavash.Components.TemplatedChipSet do
  @moduledoc """
  A chip set component using Shadow DOM + morphdom for optimistic updates.

  This component demonstrates the ClientComponent pattern where:
  1. A template is defined using `client_template`
  2. At compile time, JS hook code is generated and written to colocated hooks dir
  3. The render function is auto-generated
  4. Shadow DOM isolates the component from LiveView's DOM patching

  ## Usage

      <.live_component
        module={Lavash.Components.TemplatedChipSet}
        id="roast-filter"
        bind={[selected: :roast]}
        values={["light", "medium", "dark"]}
      />
  """

  use Lavash.ClientComponent

  bind :selected, {:array, :string}

  prop :values, {:list, :string}, required: true
  prop :labels, :map, default: %{}
  prop :chip_class, :keyword_list, default: nil

  @default_chip_class [
    base: "px-3 py-1.5 text-sm rounded-full border transition-colors cursor-pointer",
    active: "bg-primary text-primary-content border-primary",
    inactive: "bg-base-100 text-base-content/70 border-base-300 hover:border-primary/50"
  ]

  # The template - JS is generated at compile time and written to colocated hooks dir
  # The render function is also auto-generated
  client_template """
  <div class="flex flex-wrap gap-2">
    <button
      :for={v <- @values}
      type="button"
      class={if v in @selected, do: @active_class, else: @inactive_class}
      data-optimistic="toggle_selected"
      data-optimistic-value={v}
    >
      {Map.get(@labels, v, humanize(v))}
    </button>
  </div>
  """

  # State passed to the JS hook
  def client_state(assigns) do
    chip_class = assigns[:chip_class] || @default_chip_class
    base = Keyword.get(chip_class, :base, "")
    active = Keyword.get(chip_class, :active, "")
    inactive = Keyword.get(chip_class, :inactive, "")

    %{
      selected: assigns[:selected] || [],
      values: assigns.values,
      labels: assigns[:labels] || %{},
      active_class: String.trim("#{base} #{active}"),
      inactive_class: String.trim("#{base} #{inactive}")
    }
  end

  def handle_event("toggle", %{"val" => val}, socket) do
    binding_map = socket.assigns[:__lavash_binding_map__] || %{}

    case Map.get(binding_map, :selected) do
      nil ->
        selected = socket.assigns[:selected] || []

        new_selected =
          if val in selected do
            List.delete(selected, val)
          else
            [val | selected]
          end

        {:noreply, Phoenix.Component.assign(socket, :selected, new_selected)}

      parent_field ->
        send(self(), {:lavash_component_toggle, parent_field, val})
        {:noreply, socket}
    end
  end
end
