defmodule Lavash.LiveView.Helpers do
  @moduledoc """
  Helper functions available in Lavash LiveViews.
  """

  use Phoenix.Component

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

  This is equivalent to manually passing `__lavash_initial_state__`:

      <.live_component
        module={ProductCard}
        id={"product-\#{product.id}"}
        product={product}
        __lavash_initial_state__={get_component_state(@__lavash_component_states__, "product-\#{product.id}")}
      />
  """
  attr :module, :atom, required: true, doc: "The Lavash component module"
  attr :id, :string, required: true, doc: "The component ID (used for state namespacing)"
  attr :rest, :global, doc: "Additional assigns passed to the component"

  def lavash_component(assigns) do
    # Get component states from parent (set by Lavash.LiveView during mount)
    component_states = Map.get(assigns, :__lavash_component_states__, %{})
    initial_state = Map.get(component_states, assigns.id, %{})

    # Build the assigns for live_component
    assigns =
      assigns
      |> assign(:__initial_state__, initial_state)
      |> assign(:__component_assigns__,
          assigns.rest
          |> Map.put(:module, assigns.module)
          |> Map.put(:id, assigns.id)
          |> Map.put(:__lavash_initial_state__, initial_state))

    ~H"""
    <.live_component {@__component_assigns__} />
    """
  end
end
