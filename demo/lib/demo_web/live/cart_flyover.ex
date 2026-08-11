defmodule DemoWeb.CartFlyover do
  @moduledoc """
  The cart, as one self-sufficient component: header trigger (icon +
  optimistic badge), sliding panel, item rows, and totals — all
  computed from a single `client_state` projection of the cart read.

  One projection means every mutation predicts everything at once:
  increment/decrement/remove tick the rows, badge, and totals
  instantly, and `add_item` (invoked by the pages, with the product's
  display fields passed through) appends a complete provisional row —
  so even a page-initiated add updates badge, row, AND totals in the
  same tick. The `CartItem.:add` manual create dedups server-side and
  the re-read replaces provisional data with truth.

  Parents place the component where the trigger belongs:

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

  alias Demo.Cart.CartItem

  flyover do
    open_field :open
    slide_from(:right)
    width(:md)
    # Cart content is fully client-renderable (projection + subtree
    # derives) — render it while closed so optimistic opens (and the
    # add-to-cart prediction) show complete rows/totals instantly.
    render_closed(true)
  end

  prop :cart_id, :string, required: true

  read :cart_items, CartItem, :for_cart do
    argument :cart_id, prop(:cart_id)
    async false
    invalidate :pubsub

    client_state :items do
      key :id
      fields [:id, :quantity, :unit_price, product: [:id, :name, :origin, :roast_level]]
    end
  end

  calculate :item_count, rx(Enum.reduce(@items || [], 0, fn item, acc -> acc + item.quantity end))

  calculate :subtotal,
            rx(
              Enum.reduce(@items || [], 0.0, fn item, acc ->
                acc + String.to_float(item.unit_price) * item.quantity
              end)
            )

  # length/1 is deliberate in rx() — `== []` would transpile to JS
  # reference equality.
  # credo:disable-for-next-line Credo.Check.Warning.ExpensiveEmptyEnumCheck
  calculate :is_empty, rx(length(@items || []) == 0)

  calculate :grand_total, rx(Float.round(@subtotal + @tax, 2))
  calculate :tax, rx(Float.round(@subtotal * 0.08, 2))
  calculate :subtotal_formatted, rx(Float.round(@subtotal, 2))

  actions do
    action :increment, [:id] do
      mutate :items, :update_quantity, rx(%{quantity: @item.quantity + 1})
    end

    action :decrement, [:id] do
      mutate :items,
             :update_quantity,
             rx(if @item.quantity <= 1, do: :remove, else: %{quantity: @item.quantity - 1})
    end

    action :remove, [:id] do
      remove :items
    end

    # Invoked by the pages' add_to_cart. The provisional row carries
    # the product's display fields (passed through the invoke) so the
    # row, badge, and totals all predict correctly; the server half
    # runs the deduping CartItem.:add (which snapshots the real price)
    # and the re-read replaces the provisional row.
    action :add_item, [:product_id, :qty, :name, :origin, :unit_price] do
      append :items,
             :add,
             rx(%{
               cart_id: @cart_id,
               product_id: @product_id,
               quantity: @qty,
               unit_price: @unit_price,
               product: %{name: @name, origin: @origin}
             })
    end
  end

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

      <div class="flex-1 flex flex-col overflow-hidden">
        <div
          :if={@is_empty}
          class="flex flex-col items-center justify-center flex-1 text-base-content/50 p-8"
        >
          <svg class="w-16 h-16 mb-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-width="1.5"
              d="M3 3h2l.4 2M7 13h10l4-8H5.4M7 13L5.4 5M7 13l-2.293 2.293c-.63.63-.184 1.707.707 1.707H17m0 0a2 2 0 100 4 2 2 0 000-4zm-8 2a2 2 0 11-4 0 2 2 0 014 0z"
            />
          </svg>
          <p class="text-lg font-medium">Your cart is empty</p>
          <p class="text-sm mt-1">Add some coffee to get started</p>
        </div>

        <div :if={!@is_empty} class="flex-1 overflow-auto divide-y divide-base-200">
          <div :for={item <- @items} class="p-4 flex gap-4">
            <div class="w-20 h-20 bg-base-200 rounded-lg flex-shrink-0 overflow-hidden flex items-center justify-center text-base-content/30">
              <svg class="w-8 h-8" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="1.5"
                  d="M20 7l-8-4-8 4m16 0l-8 4m8-4v10l-8 4m0-10L4 7m8 4v10M4 7v10l8 4"
                />
              </svg>
            </div>

            <div class="flex-1 min-w-0">
              <h3 class="font-medium truncate">{item.product.name}</h3>
              <p class="text-sm text-base-content/60">{item.product.origin}</p>
              <p class="text-sm font-medium mt-1">${item.unit_price}</p>

              <div class="flex items-center gap-2 mt-2">
                <button
                  type="button"
                  class="btn btn-xs btn-circle btn-ghost"
                  phx-click="decrement"
                  phx-value-id={item.id}
                >
                  <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M20 12H4"
                    />
                  </svg>
                </button>
                <span class="w-8 text-center font-medium">{item.quantity}</span>
                <button
                  type="button"
                  class="btn btn-xs btn-circle btn-ghost"
                  phx-click="increment"
                  phx-value-id={item.id}
                >
                  <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M12 4v16m8-8H4"
                    />
                  </svg>
                </button>
                <button
                  type="button"
                  class="btn btn-xs btn-ghost text-error ml-auto"
                  phx-click="remove"
                  phx-value-id={item.id}
                >
                  Remove
                </button>
              </div>
            </div>
          </div>
        </div>

        <!-- Footer with totals -->
        <div
          :if={!@is_empty}
          class="p-4 border-t border-base-300 space-y-4 bg-base-100 flex-shrink-0"
        >
          <div class="flex justify-between">
            <span>Subtotal</span>
            <span>${@subtotal_formatted}</span>
          </div>
          <div class="flex justify-between text-sm text-base-content/60">
            <span>Tax (8%)</span>
            <span>${@tax}</span>
          </div>
          <div class="flex justify-between text-lg font-bold">
            <span>Total</span>
            <span>${@grand_total}</span>
          </div>
          <%!-- Live navigation, not a plain anchor: it rides the same
               channel as any just-clicked mutate event, so in-flight cart
               writes commit (in order) before the checkout view mounts. --%>
          <.link navigate="/storefront/checkout" class="btn btn-primary w-full">Checkout</.link>
          <%!-- Canonical close path: dispatch close-panel to the chrome,
               same as the header close button — the client handler runs
               the versioned :close the flyover DSL injects. --%>
          <button
            type="button"
            class="btn btn-ghost w-full"
            phx-click={Phoenix.LiveView.JS.dispatch("close-panel", to: "##{@__flyover_id__}")}
          >
            Continue Shopping
          </button>
        </div>
      </div>
    </div>
    """
  end
end
