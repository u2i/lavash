defmodule DemoWeb.CartFlyover do
  @moduledoc """
  A Shopify-style sliding cart panel.

  Opens from the right when items are added to cart or cart icon is clicked.
  Displays cart items with quantity controls and subtotal.
  """
  use Lavash.Component, extensions: [Lavash.Overlay.Flyover.Dsl]

  import Lavash.Overlay.Flyover.Helpers, only: [flyover_close_button: 1]

  flyover do
    open_field :open
    slide_from :right
    width :md
  end

  # Props from parent LiveView
  prop :items, :list, default: []
  prop :subtotal, :any, default: nil
  prop :item_count, :integer, default: 0

  render fn assigns ->
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

      <!-- Cart Items (scrollable) -->
      <div class="flex-1 overflow-auto">
        <%= if @items == [] do %>
          <div class="flex flex-col items-center justify-center h-full text-base-content/50 p-8">
            <svg class="w-16 h-16 mb-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M3 3h2l.4 2M7 13h10l4-8H5.4M7 13L5.4 5M7 13l-2.293 2.293c-.63.63-.184 1.707.707 1.707H17m0 0a2 2 0 100 4 2 2 0 000-4zm-8 2a2 2 0 11-4 0 2 2 0 014 0z" />
            </svg>
            <p class="text-lg font-medium">Your cart is empty</p>
            <p class="text-sm mt-1">Add some coffee to get started</p>
            <button class="btn btn-primary btn-sm mt-4" phx-click={@on_close}>
              Browse Coffees
            </button>
          </div>
        <% else %>
          <div class="divide-y divide-base-200">
            <%= for item <- @items do %>
              <div class="p-4 flex gap-4">
                <!-- Product image -->
                <div class="w-20 h-20 bg-base-200 rounded-lg flex-shrink-0 overflow-hidden">
                  <img
                    src={"https://images.unsplash.com/#{coffee_image(item.product.roast_level)}?w=200&q=80"}
                    alt={item.product.name}
                    class="w-full h-full object-cover"
                  />
                </div>

                <div class="flex-1 min-w-0">
                  <h3 class="font-medium truncate">{item.product.name}</h3>
                  <p class="text-sm text-base-content/60">{item.product.origin}</p>
                  <p class="text-sm font-medium mt-1">${Decimal.to_string(item.unit_price)}</p>

                  <!-- Quantity controls - target parent LV for mutations -->
                  <div class="flex items-center gap-2 mt-2">
                    <button
                      class="btn btn-xs btn-circle btn-ghost"
                      phx-click="update_cart_item"
                      phx-value-item_id={item.id}
                      phx-value-delta={-1}
                    >
                      <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M20 12H4" />
                      </svg>
                    </button>
                    <span class="w-8 text-center font-medium">{item.quantity}</span>
                    <button
                      class="btn btn-xs btn-circle btn-ghost"
                      phx-click="update_cart_item"
                      phx-value-item_id={item.id}
                      phx-value-delta={1}
                    >
                      <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4" />
                      </svg>
                    </button>
                    <button
                      class="btn btn-xs btn-ghost text-error ml-auto"
                      phx-click="remove_cart_item"
                      phx-value-item_id={item.id}
                    >
                      Remove
                    </button>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>

      <!-- Footer with totals -->
      <div :if={@items != []} class="p-4 border-t border-base-300 space-y-4 bg-base-100">
        <div class="flex justify-between text-lg font-bold">
          <span>Subtotal</span>
          <span>${format_price(@subtotal)}</span>
        </div>
        <p class="text-sm text-base-content/60">Shipping calculated at checkout</p>
        <button class="btn btn-primary w-full">Checkout</button>
        <button class="btn btn-ghost w-full" phx-click={@on_close}>Continue Shopping</button>
      </div>
    </div>
    """
  end

  # Cart mutations are handled by the parent LiveView (ProductsLive)
  # Button clicks without phx-target bubble up to the parent.
  # PubSub invalidation auto-refreshes the cart_items read.

  defp coffee_image(roast_level) do
    case roast_level do
      :light -> "photo-1495474472287-4d71bcdd2085"
      :medium -> "photo-1559056199-641a0ac8b55e"
      :medium_dark -> "photo-1509042239860-f550ce710b93"
      :dark -> "photo-1514432324607-a09d9b4aefdd"
      _ -> "photo-1447933601403-0c6688de566e"
    end
  end

  defp format_price(nil), do: "0.00"
  defp format_price(%Decimal{} = d), do: Decimal.to_string(d)
  defp format_price(other), do: to_string(other)
end
