defmodule DemoWeb.CartFlyover do
  @moduledoc """
  A Shopify-style sliding cart panel that owns its own trigger.

  The component renders everything cart-related: the header cart icon
  with an optimistic count badge (`template_trigger` — rendered outside
  the panel chrome, wired with dialog ARIA and an optimistic open), and
  the sliding panel hosting `CartItemList`.

  It reads the cart itself (pubsub-invalidated) and projects `{id,
  quantity}` to the client, so the badge count is a fully optimistic
  calc: it ticks instantly on in-cart mutations and converges across
  sessions via broadcast.

  Parents only pass `cart_id` (and may bind `open` to auto-open from
  their own actions, e.g. add-to-cart):

      <.lavash_component
        module={DemoWeb.CartFlyover}
        id="cart-flyover"
        cart_id={@cart_id}
        open={@cart_open}
        bind={[open: :cart_open]}
      />
  """
  use Lavash.Component, extensions: [Lavash.Overlay.Flyover.Dsl]

  import Lavash.Overlay.Flyover.Helpers, only: [flyover_close_button: 1]
  import Lavash.LiveView.Helpers, only: [lavash_component: 1]

  alias Demo.Cart.CartItem

  flyover do
    open_field :open
    slide_from(:right)
    width(:md)
  end

  prop :cart_id, :string, required: true

  # Badge data: a lean projection of the same cart CartItemList reads
  # in full — both converge through pubsub invalidation.
  read :cart_badge_items, CartItem, :for_cart do
    argument :cart_id, prop(:cart_id)
    async false
    invalidate :pubsub

    client_state :badge_items do
      key :id
      fields [:id, :quantity]
    end
  end

  calculate :item_count,
            rx(Enum.reduce(@badge_items || [], 0, fn item, acc -> acc + item.quantity end))

  template_trigger do
    ~H"""
    <span class="btn btn-ghost btn-circle relative">
      <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          stroke-width="2"
          d="M3 3h2l.4 2M7 13h10l4-8H5.4M7 13L5.4 5M7 13l-2.293 2.293c-.63.63-.184 1.707.707 1.707H17m0 0a2 2 0 100 4 2 2 0 000-4zm-8 2a2 2 0 11-4 0 2 2 0 014 0z"
        />
      </svg>
      <span :if={@item_count > 0} class="badge badge-sm badge-primary absolute -top-1 -right-1">
        {@item_count}
      </span>
    </span>
    """
  end

  template do
    ~H"""
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

      <!-- Cart Items - self-sufficient component (includes footer with subtotal) -->
      <.lavash_component
        module={DemoWeb.Components.CartItemList}
        id="cart-item-list"
        bind={[open: :open]}
        cart_id={@cart_id}
        open={@open}
        myself={@myself}
      />
    </div>
    """
  end
end
