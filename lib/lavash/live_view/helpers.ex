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
    # Get component states from process dictionary (set by parent during render)
    component_states = get_component_states()
    initial_state = Map.get(component_states, assigns.id, %{})

    # Build the assigns for live_component
    assigns =
      assigns
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
