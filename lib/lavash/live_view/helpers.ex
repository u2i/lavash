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
  Builds the optimistic state map from assigns based on DSL metadata.

  Collects all state fields and derives marked with `optimistic: true` and
  extracts their current values from assigns. For async derives, unwraps the
  `{:ok, value}` tuple to get the raw value.

  ## Example

      # In your LiveView module
      state :count, :integer, from: :url, default: 0, optimistic: true
      state :multiplier, :integer, from: :ephemeral, default: 2, optimistic: true

      derive :doubled, optimistic: true do
        # ...
      end

      # In render/1
      def render(assigns) do
        assigns = assign(assigns, :optimistic_state, optimistic_state(__MODULE__, assigns))
        # ...
      end
  """
  def optimistic_state(module, assigns) do
    # Get optimistic state fields
    state_fields = module.__lavash__(:optimistic_fields)

    # Get optimistic derives
    derives = module.__lavash__(:optimistic_derives)

    # Build the state map
    state_map =
      Enum.reduce(state_fields, %{}, fn field, acc ->
        value = Map.get(assigns, field.name)
        Map.put(acc, field.name, value)
      end)

    # Add derives, unwrapping async values
    Enum.reduce(derives, state_map, fn derive, acc ->
      value = Map.get(assigns, derive.name)

      # Unwrap async values - handle both AsyncResult structs and plain tuples
      value =
        case value do
          %Phoenix.LiveView.AsyncResult{ok?: true, result: v} -> v
          %Phoenix.LiveView.AsyncResult{loading: loading} when loading != nil -> nil
          %Phoenix.LiveView.AsyncResult{} -> nil
          {:ok, v} -> v
          :loading -> nil
          {:error, _} -> nil
          v -> v
        end

      Map.put(acc, derive.name, value)
    end)
  end

  @doc """
  Renders an optimistic display element.

  This component eliminates the duplication of specifying both the field name
  and value when displaying optimistic state. It generates a wrapper element
  with the appropriate `data-optimistic-display` attribute.

  ## Examples

      # Simple usage - renders a span
      <.o field={:count} value={@count} />
      # Outputs: <span data-optimistic-display="count">5</span>

      # With custom tag
      <.o field={:count} value={@count} tag="div" />
      # Outputs: <div data-optimistic-display="count">5</div>

      # With additional attributes
      <.o field={:doubled} value={@doubled} class="text-xl font-bold" />
      # Outputs: <span data-optimistic-display="doubled" class="text-xl font-bold">10</span>

      # With inner block for custom content (value still used for optimistic updates)
      <.o field={:count} value={@count}>
        Count: {@count}
      </.o>
      # Outputs: <span data-optimistic-display="count">Count: 5</span>
  """
  attr :field, :atom, required: true, doc: "The state/derive field name"
  attr :value, :any, required: true, doc: "The current value from assigns"
  attr :tag, :string, default: "span", doc: "The HTML tag to use (default: span)"
  attr :rest, :global, doc: "Additional HTML attributes"
  slot :inner_block, doc: "Optional custom content (defaults to displaying value)"

  def o(assigns) do
    assigns = assign(assigns, :field_name, to_string(assigns.field))

    ~H"""
    <.dynamic_tag name={@tag} data-optimistic-display={@field_name} {@rest}>
      <%= if @inner_block != [] do %>
        {render_slot(@inner_block)}
      <% else %>
        {@value}
      <% end %>
    </.dynamic_tag>
    """
  end

  @doc """
  Renders a Lavash component with automatic state hydration.

  This function component wraps `Phoenix.Component.live_component/1` and automatically
  injects the component's persisted state from the parent's `@__lavash_component_states__`.

  ## Example

      <.lavash_component
        module={ProductCard}
        id={"product-\#{product.id}"}
        product={product}
      />
  """
  attr(:module, :atom, required: true, doc: "The Lavash component module")
  attr(:id, :string, required: true, doc: "The component ID (used for state namespacing)")
  attr(:rest, :global, doc: "Additional assigns passed to the component")

  def lavash_component(assigns) do
    # Get component states from process dictionary (set by parent during render)
    component_states = get_component_states()
    initial_state = Map.get(component_states, assigns.id, %{})

    # Build the assigns for live_component
    assigns =
      assigns
      |> assign(
        :__component_assigns__,
        assigns.rest
        |> Map.put(:module, assigns.module)
        |> Map.put(:id, assigns.id)
        |> Map.put(:__lavash_initial_state__, initial_state)
      )

    ~H"""
    <.live_component {@__component_assigns__} />
    """
  end
end
