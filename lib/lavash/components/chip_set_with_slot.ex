defmodule Lavash.Components.ChipSetWithSlot do
  @moduledoc """
  A chip set component with a slot for non-optimistic nested content.

  Demonstrates the hybrid approach where:
  - Chip buttons are optimistically rendered by the client
  - Slot content is preserved and only updated by server patches

  ## Usage

      <.live_component
        module={Lavash.Components.ChipSetWithSlot}
        id="roast-filter"
        bind={[selected: :roast]}
        selected={@roast}
        values={["light", "medium", "dark"]}
      >
        <:footer>
          <div>Server timestamp: <%= @server_timestamp %></div>
        </:footer>
      </.live_component>
  """

  use Lavash.ClientComponent

  bind :selected, {:array, :string}

  prop :values, {:list, :string}, required: true
  prop :labels, :map, default: %{}
  prop :chip_class, :keyword_list, default: nil

  calculate :selected_count, length(@selected)

  @default_chip_class [
    base: "px-3 py-1.5 text-sm rounded-full border transition-colors cursor-pointer",
    active: "bg-primary text-primary-content border-primary",
    inactive: "bg-base-100 text-base-content/70 border-base-300 hover:border-primary/50"
  ]

  # The template includes a placeholder for the slot that will be preserved
  # The data-lavash-preserve attribute tells morphdom to skip this element
  client_template """
  <div>
    <div class="flex flex-wrap gap-2 items-center">
      <button
        :for={v <- @values}
        type="button"
        class={if v in @selected, do: @active_class, else: @inactive_class}
        data-optimistic="toggle_selected"
        data-optimistic-value={v}
      >
        {Map.get(@labels, v, humanize(v))}
      </button>
      <span class="text-sm text-gray-600 ml-2">
        (<span data-optimistic-display="selected_count">{@selected_count}</span> selected)
      </span>
    </div>
    <div data-lavash-preserve="footer" class="mt-4"></div>
  </div>
  """

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

  # Override render to inject slot content into the preserved placeholder
  def render(var!(assigns)) do
    # Get the base render from ClientComponent
    state = client_state(var!(assigns))
    state = __compute_calculations__(state)
    state_json = Jason.encode!(state)

    version = Map.get(var!(assigns), :__lavash_version__, 0)
    binding_map = Map.get(var!(assigns), :__lavash_binding_map__, %{})
    bindings_json = Jason.encode!(binding_map)

    var!(assigns) =
      var!(assigns)
      |> Phoenix.Component.assign(:client_state, state)
      |> Phoenix.Component.assign(:__state_json__, state_json)
      |> Phoenix.Component.assign(:__bindings_json__, bindings_json)
      |> Phoenix.Component.assign(:__hook_name__, __full_hook_name__())
      |> Phoenix.Component.assign(:__version__, version)
      |> Phoenix.Component.assign(state)

    ~H"""
    <div
      id={@id}
      phx-hook={@__hook_name__}
      phx-target={@myself}
      data-lavash-state={@__state_json__}
      data-lavash-version={@__version__}
      data-lavash-bindings={@__bindings_json__}
    >
      <div>
        <div class="flex flex-wrap gap-2 items-center">
          <button
            :for={v <- @values}
            type="button"
            class={if v in @selected, do: @active_class, else: @inactive_class}
            data-optimistic="toggle_selected"
            data-optimistic-value={v}
            phx-click="toggle"
            phx-value-val={v}
            phx-target={@myself}
          >
            {Map.get(@labels, v, humanize(v))}
          </button>
          <span class="text-sm text-gray-600 ml-2">
            (<span data-optimistic-display="selected_count">{@selected_count}</span> selected)
          </span>
        </div>
        <%!-- This div is preserved during client renders, only server patches it --%>
        <div data-lavash-preserve="footer" class="mt-4">
          {render_slot(@footer)}
        </div>
      </div>
    </div>
    """
  end

  def handle_event("toggle", %{"val" => val}, socket) do
    binding_map = socket.assigns[:__lavash_binding_map__] || %{}

    case Map.get(binding_map, :selected) do
      nil ->
        socket = bump_version(socket)
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
