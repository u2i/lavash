defmodule DemoWeb.Components.CartItemList do
  @moduledoc """
  Optimistic cart item list with key-based array mutations.

  This ClientComponent handles:
  - Incrementing/decrementing item quantities
  - Removing items from cart
  - Automatic subtotal recalculation

  All mutations happen instantly on the client (optimistic), then sync with server.

  ## Usage

      <.live_component
        module={DemoWeb.Components.CartItemList}
        id="cart-items"
        bind={[items: :cart_items_json]}
        items={@cart_items_json}
      />

  ## How it works

  1. User clicks +/- button -> client instantly updates quantity
  2. Server receives event and updates database
  3. When server confirms, client syncs version

  Uses key-based optimistic_action with `:id` key to find and update
  specific items in the array.
  """

  use Lavash.ClientComponent

  # Cart items as array of maps: %{id, quantity, unit_price, product: %{...}}
  state :items, {:array, :map}

  # Bound to parent's flyover open state - allows closing from within
  state :open, :boolean

  # Calculations for display
  calculate :item_count, rx(Enum.reduce(@items || [], 0, fn item, acc -> acc + item.quantity end))

  calculate :subtotal,
            rx(
              Enum.reduce(@items || [], 0.0, fn item, acc ->
                acc + String.to_float(item.unit_price) * item.quantity
              end)
            )

  calculate :is_empty, rx(length(@items || []) == 0)

  # Key-based optimistic actions
  # The :key option tells the system to find items by :id field

  optimistic_action :increment, :items,
    key: :id,
    run: fn item, _delta -> %{item | quantity: item.quantity + 1} end

  optimistic_action :decrement, :items,
    key: :id,
    run: fn item, _delta ->
      if item.quantity <= 1 do
        :remove
      else
        %{item | quantity: item.quantity - 1}
      end
    end

  optimistic_action :remove, :items,
    key: :id,
    run: :remove

  # Close the flyover by setting open to false
  optimistic_action :close, :open,
    run: :set


  # Helper to format subtotal with 2 decimal places
  calculate :subtotal_formatted, rx(Float.round(@subtotal, 2))

  template """
  <div class="flex-1 flex flex-col overflow-hidden">
    <div :if={@is_empty} class="flex flex-col items-center justify-center flex-1 text-base-content/50 p-8">
      <svg class="w-16 h-16 mb-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path stroke-linecap="round" stroke-width="1.5" d="M3 3h2l.4 2M7 13h10l4-8H5.4M7 13L5.4 5M7 13l-2.293 2.293c-.63.63-.184 1.707.707 1.707H17m0 0a2 2 0 100 4 2 2 0 000-4zm-8 2a2 2 0 11-4 0 2 2 0 014 0z" />
      </svg>
      <p class="text-lg font-medium">Your cart is empty</p>
      <p class="text-sm mt-1">Add some coffee to get started</p>
    </div>

    <div :if={!@is_empty} class="flex-1 overflow-auto divide-y divide-base-200">
      <div :for={item <- @items} class="p-4 flex gap-4">
        <!-- Product image placeholder -->
        <div class="w-20 h-20 bg-base-200 rounded-lg flex-shrink-0 overflow-hidden flex items-center justify-center text-base-content/30">
          <svg class="w-8 h-8" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M20 7l-8-4-8 4m16 0l-8 4m8-4v10l-8 4m0-10L4 7m8 4v10M4 7v10l8 4" />
          </svg>
        </div>

        <div class="flex-1 min-w-0">
          <h3 class="font-medium truncate">{item.product.name}</h3>
          <p class="text-sm text-base-content/60">{item.product.origin}</p>
          <p class="text-sm font-medium mt-1">${item.unit_price}</p>

          <!-- Quantity controls -->
          <div class="flex items-center gap-2 mt-2">
            <button
              type="button"
              class="btn btn-xs btn-circle btn-ghost"
              data-lavash-action="decrement"
              data-lavash-value={item.id}
            >
              <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M20 12H4" />
              </svg>
            </button>
            <span class="w-8 text-center font-medium">{item.quantity}</span>
            <button
              type="button"
              class="btn btn-xs btn-circle btn-ghost"
              data-lavash-action="increment"
              data-lavash-value={item.id}
            >
              <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4" />
              </svg>
            </button>
            <button
              type="button"
              class="btn btn-xs btn-ghost text-error ml-auto"
              data-lavash-action="remove"
              data-lavash-value={item.id}
            >
              Remove
            </button>
          </div>
        </div>
      </div>
    </div>

    <!-- Footer with totals (inside ClientComponent for optimistic subtotal) -->
    <div :if={!@is_empty} class="p-4 border-t border-base-300 space-y-4 bg-base-100 flex-shrink-0">
      <div class="flex justify-between text-lg font-bold">
        <span>Subtotal</span>
        <span>${@subtotal_formatted}</span>
      </div>
      <p class="text-sm text-base-content/60">Shipping calculated at checkout</p>
      <button class="btn btn-primary w-full">Checkout</button>
      <button
        type="button"
        class="btn btn-ghost w-full"
        data-lavash-action="close"
        data-lavash-value="false"
      >
        Continue Shopping
      </button>
    </div>
  </div>
  """
end
