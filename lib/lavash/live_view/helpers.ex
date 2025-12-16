defmodule Lavash.LiveView.Helpers do
  @moduledoc """
  Helper functions available in Lavash LiveViews.
  """

  use Phoenix.Component

  @doc """
  Stores component states in process dictionary for child components to access.
  Call this at the start of your render function, or use the `lavash_render` wrapper.
  """
  def put_component_states(states) do
    Process.put(:__lavash_component_states__, states)
  end

  @doc """
  Gets component states from process dictionary.
  """
  def get_component_states do
    Process.get(:__lavash_component_states__, %{})
  end

  @doc """
  Renders a Lavash component with automatic state hydration.

  This function component wraps `Phoenix.Component.live_component/1` and automatically
  injects the component's persisted state from the parent's `@__lavash_component_states__`.

  ## Two-way binding with `bind`

  Use the `bind` attribute to create two-way bindings between parent state and component props.
  When the component emits changes to a bound prop, the parent's state is automatically updated.

  The bind map specifies `{component_prop, {parent_field, current_value}}`:

  ## Example

      <.lavash_component
        module={ProductEditModal}
        id="modal"
        bind={%{product_id: {:editing_product_id, @editing_product_id}}}
      />

  This creates a two-way binding where:
  - The component receives `@product_id` with the value of `@editing_product_id`
  - When the component calls `emit :product_id, nil`, the parent's `:editing_product_id` is set to `nil`

  ## Regular props

      <.lavash_component
        module={ProductCard}
        id={"product-\#{product.id}"}
        product={product}
      />
  """
  attr :module, :atom, required: true, doc: "The Lavash component module"
  attr :id, :string, required: true, doc: "The component ID (used for state namespacing)"
  attr :bind, :map, default: %{}, doc: "Two-way bindings: %{component_prop: {:parent_field, value}}"
  attr :rest, :global, doc: "Additional assigns passed to the component"

  def lavash_component(assigns) do
    # Get component states from process dictionary (set by parent during render)
    component_states = get_component_states()
    initial_state = Map.get(component_states, assigns.id, %{})

    # Process bindings: convert %{prop: {:parent_field, value}} to binding info and prop values
    {bindings, bound_props} = process_bindings(assigns.bind)

    # Build the assigns for live_component
    assigns =
      assigns
      |> assign(:__component_assigns__,
          assigns.rest
          |> Map.merge(bound_props)
          |> Map.put(:module, assigns.module)
          |> Map.put(:id, assigns.id)
          |> Map.put(:__lavash_initial_state__, initial_state)
          |> Map.put(:__lavash_bindings__, bindings))

    ~H"""
    <.live_component {@__component_assigns__} />
    """
  end

  # Process bind map: %{product_id: {:editing_product_id, value}} becomes:
  #   - bindings: %{product_id: "update:editing_product_id"}
  #   - bound_props: %{product_id: value}
  defp process_bindings(bind_map) do
    Enum.reduce(bind_map, {%{}, %{}}, fn {prop_name, {parent_field, value}}, {bindings, props} ->
      # Create the binding info: prop_name -> "update:parent_field"
      event_name = "update:#{parent_field}"

      {
        Map.put(bindings, prop_name, event_name),
        Map.put(props, prop_name, value)
      }
    end)
  end
end
