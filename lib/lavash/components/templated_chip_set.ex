defmodule Lavash.Components.TemplatedChipSet do
  @moduledoc """
  A chip set component using compile-time template generation.

  This component demonstrates the Shadow DOM + morphdom approach where:
  1. A colocated JS hook is generated at compile time from the template
  2. The hook renders into a Shadow DOM for isolation from LiveView patching
  3. morphdom efficiently diffs and patches the Shadow DOM on state changes

  ## Usage

      # In parent LiveView:
      state :roast, {:array, :string}, from: :url, default: []

      # In template:
      <.live_component
        module={Lavash.Components.TemplatedChipSet}
        id="roast-filter"
        bind={[selected: :roast]}
        values={["light", "medium", "dark"]}
      />
  """

  use Lavash.LiveComponent

  # Binding declaration - this gets connected to parent state
  bind :selected, {:array, :string}

  # Props passed from parent
  prop :values, {:list, :string}, required: true
  prop :labels, :map, default: %{}
  prop :chip_class, :keyword_list, default: nil

  @default_chip_class [
    base: "px-3 py-1.5 text-sm rounded-full border transition-colors cursor-pointer",
    active: "bg-primary text-primary-content border-primary",
    inactive: "bg-base-100 text-base-content/70 border-base-300 hover:border-primary/50"
  ]

  # The template that will be compiled to both HEEx and JS
  @template """
  <div class="flex flex-wrap gap-2">
    <button
      :for={v <- @values}
      type="button"
      class={if v in (@selected || []), do: @active_class, else: @inactive_class}
      phx-click="toggle"
      phx-value-val={v}
      data-optimistic="toggle_selected"
      data-optimistic-value={v}
    >
      {Map.get(@labels || %{}, v, humanize(v))}
    </button>
  </div>
  """

  # Compile template at compile time
  @generated_js (
    {_heex, js} = Lavash.Template.compile_template(@template)
    js
  )

  def render(assigns) do
    chip_class = assigns[:chip_class] || @default_chip_class
    base = Keyword.get(chip_class, :base, "")
    active = Keyword.get(chip_class, :active, "")
    inactive = Keyword.get(chip_class, :inactive, "")

    assigns =
      assigns
      |> Phoenix.Component.assign(:active_class, String.trim("#{base} #{active}"))
      |> Phoenix.Component.assign(:inactive_class, String.trim("#{base} #{inactive}"))

    # Build the state JSON for the hook
    state = %{
      selected: assigns[:selected] || [],
      values: assigns.values,
      labels: assigns[:labels] || %{},
      active_class: assigns.active_class,
      inactive_class: assigns.inactive_class
    }

    assigns = Phoenix.Component.assign(assigns, :state_json, Jason.encode!(state))

    ~H"""
    <div id={@id}>
      <div
        id={"#{@id}-hook"}
        phx-hook="TemplatedChipSet"
        phx-target={@myself}
        data-lavash-state={@state_json}
        data-lavash-version="0"
      >
        <%!-- JS hook renders into Shadow DOM, this is just a container --%>
      </div>
    </div>
    """
  end

  # Return the generated JS for external access (compile-time constant)
  def __generated_js__, do: @generated_js

  def handle_event("toggle", %{"val" => val}, socket) do
    require Logger
    Logger.warning("[TemplatedChipSet] toggle event: val=#{val}")

    binding_map = socket.assigns[:__lavash_binding_map__] || %{}

    case Map.get(binding_map, :selected) do
      nil ->
        # Not bound - update locally
        selected = socket.assigns[:selected] || []

        new_selected =
          if val in selected do
            List.delete(selected, val)
          else
            [val | selected]
          end

        {:noreply, Phoenix.Component.assign(socket, :selected, new_selected)}

      parent_field ->
        # Bound to parent - send toggle operation
        send(self(), {:lavash_component_toggle, parent_field, val})
        {:noreply, socket}
    end
  end

  defp humanize(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
