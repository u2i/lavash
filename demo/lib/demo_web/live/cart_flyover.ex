defmodule DemoWeb.CartFlyover do
  @moduledoc """
  A Shopify-style sliding cart panel.

  Opens from the right when items are added to cart or cart icon is clicked.
  Uses a ClientComponent (CartItemList) inside for optimistic cart mutations.

  Architecture:
  - Flyover DSL handles panel behavior (slide animation, backdrop, open/close)
  - CartItemList ClientComponent handles item mutations optimistically
  - Parent LiveView owns the cart data and database mutations
  """
  use Lavash.Component, extensions: [Lavash.Overlay.Flyover.Dsl]

  import Lavash.Overlay.Flyover.Helpers, only: [flyover_close_button: 1]
  import Lavash.Component.Helpers, only: [child_component: 1]

  flyover do
    open_field :open
    slide_from :right
    width :md
  end

  # Props from parent LiveView
  prop :items, :list, default: []
  prop :item_count, :integer, default: 0

  render fn assigns ->
    ~L"""
    <div class="h-full flex flex-col">
      <!-- Header -->
      <div class="flex items-center justify-between p-4 border-b border-base-300">
        <h2 class="text-lg font-bold">
          Your Cart
          <span :if={@item_count > 0} class="badge badge-sm badge-primary ml-2">
            {@item_count}
          </span>
        </h2>
        <.flyover_close_button id={@__flyover_id__} myself={@myself} />
      </div>

      <!-- Cart Items - ClientComponent for optimistic updates (includes footer with subtotal) -->
      <.child_component
        module={DemoWeb.Components.CartItemList}
        id="cart-item-list"
        bind={[items: :cart_items_json, open: :open]}
        items={@items}
        open={@open}
        myself={@myself}
      />
    </div>
    """
  end
end
