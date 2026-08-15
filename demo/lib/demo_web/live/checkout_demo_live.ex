defmodule DemoWeb.CheckoutDemoLive do
  @moduledoc """
  Shopify-style checkout demo.

  This is the real storefront checkout — same cart, addresses, and
  order placement as `DemoWeb.Storefront.CheckoutLive` — wrapped in
  Shopify-styled chrome. All logic comes from
  `DemoWeb.Checkout.Shared`, all shared markup from
  `DemoWeb.Checkout.Components`; the only page-specific piece is the
  `seed_cart` action so the demo works without a shopping trip.

  Demonstrates:
  - Ash `form` DSL for auto-generated validation from resource constraints
  - `extend_errors` for custom validation messages beyond Ash constraints
  - `import_rx` for importing reusable reactive validation functions
  - Card type detection via `rx()` with optimistic badge updates
  - `data-lavash-toggle` / `data-lavash-visible` / `data-lavash-enabled`
  - Real SQLite-backed cart, addresses, and orders per anonymous visitor
  """
  use Lavash.LiveView
  use DemoWeb.Checkout.Shared

  alias Demo.Catalog.Product

  # ─────────────────────────────────────────────────────────────────
  # Demo-only: fill the cart with sample items
  # ─────────────────────────────────────────────────────────────────

  actions do
    action :seed_cart do
      run fn socket -> seed_cart(socket) end
    end
  end

  # Adds up to two catalog products to the visitor's cart (creating a
  # sample product first if the catalog is empty) so the demo can be
  # exercised end to end without visiting the store.
  defp seed_cart(socket) do
    products =
      case Ash.read!(Product) do
        [] ->
          [
            Product
            |> Ash.Changeset.for_create(:create, %{
              name: "Bali Blue Moon",
              price: Decimal.new("20.00")
            })
            |> Ash.create!()
          ]

        products ->
          Enum.take(products, 2)
      end

    cart_id = socket.assigns.cart_id

    Enum.each(products, fn product ->
      Demo.Cart.CartItem
      |> Ash.Changeset.for_create(:create_row, %{
        cart_id: cart_id,
        product_id: product.id,
        quantity: 1
      })
      |> Ash.create!()
    end)

    # Raw Ash.create! bypasses lavash's form machinery, which is what
    # normally broadcasts notify_on mutations — invalidate the
    # cart_id-scoped reads (this page, cart flyover, store checkout)
    # ourselves.
    Lavash.PubSub.broadcast_mutation(Demo.Cart.CartItem, [:cart_id], %{cart_id: {nil, cart_id}})

    socket
  end

  # ─────────────────────────────────────────────────────────────────
  # Template — Shopify-styled chrome around the shared checkout
  # ─────────────────────────────────────────────────────────────────

  template do
    ~H"""
    <div id="checkout-demo" data-theme="shopify" class="bg-base-200 min-h-screen">
      <main class="mx-auto max-w-6xl p-4 lg:p-8">
        <%= if @order_placed_id do %>
          <.order_placed
            order_id={@order_placed_id}
            subtotal_display={@subtotal_display}
            tax_display={@tax_display}
            shipping_display={@shipping_display}
            total_display={@total_display}
          />
        <% else %>
          <%= if @is_empty do %>
            <.empty_cart>
              <:seed>
                <button phx-click="seed_cart" class="btn btn-outline">
                  Add sample items
                </button>
              </:seed>
            </.empty_cart>
          <% else %>
            <div class="grid grid-cols-1 gap-6 lg:grid-cols-[1.6fr_1fr]">
              <!-- LEFT COLUMN -->
              <section class="card border border-base-300 bg-base-100 shadow-sm">
                <div class="card-body gap-6">
                  <!-- Express checkout (decorative Shopify chrome) -->
                  <div class="flex flex-col gap-3">
                    <div class="join w-full">
                      <button class="btn join-item btn-primary w-1/3 font-bold">shop</button>
                      <button class="btn join-item w-1/3 bg-yellow-400 text-slate-900 border-yellow-400 font-bold hover:bg-yellow-500">
                        PayPal
                      </button>
                      <button class="btn join-item btn-info w-1/3 font-bold text-white">
                        venmo
                      </button>
                    </div>

                    <div class="divider text-xs font-semibold text-base-content/50 uppercase">
                      OR
                    </div>

                    <!-- Signed-in row: the real (anonymous) visitor identity -->
                    <div class="flex items-center justify-between">
                      <div class="flex items-center gap-3">
                        <div class="avatar placeholder">
                          <div class="w-9 rounded-full bg-base-200 text-base-content">
                            <span class="text-sm font-bold">G</span>
                          </div>
                        </div>
                        <div class="text-sm font-semibold text-base-content/70">
                          {if @current_user && !@current_user.anonymous,
                            do: @current_user.email,
                            else: "Guest checkout"}
                        </div>
                      </div>
                      <button class="btn btn-ghost btn-sm" aria-label="More">&#8942;</button>
                    </div>
                  </div>

                  <.ship_to
                    addresses={@addresses}
                    selected_address={@selected_address}
                    ship_to_expanded={@ship_to_expanded}
                  />

                  <.shipping_method shipping_display={@shipping_display} />

                  <.payment_section
                    payment={@payment}
                    payment_method={@payment_method}
                    use_shipping_as_billing={@use_shipping_as_billing}
                    can_place={@can_place}
                    total={@total}
                    card_type_display={@card_type_display}
                    has_card_type={@has_card_type}
                    show_visa={@show_visa}
                    show_mastercard={@show_mastercard}
                    show_amex={@show_amex}
                    show_discover={@show_discover}
                    card_number_valid={@card_number_valid}
                    expiry_valid={@expiry_valid}
                    cvv_valid={@cvv_valid}
                    payment_name_valid={@payment_name_valid}
                    payment_card_number_errors={@payment_card_number_errors}
                    payment_expiry_errors={@payment_expiry_errors}
                    payment_cvv_errors={@payment_cvv_errors}
                    payment_name_errors={@payment_name_errors}
                  />
                </div>
              </section>

              <!-- RIGHT COLUMN - Order Summary + demo notes -->
              <aside class="lg:sticky lg:top-5 self-start space-y-4">
                <.order_summary
                  cart_items={@cart_items}
                  subtotal_display={@subtotal_display}
                  tax_display={@tax_display}
                  shipping_display={@shipping_display}
                  total_display={@total_display}
                />

                <.test_cards />

                <!-- How it works -->
                <div class="p-4 bg-base-100 rounded-lg border border-base-300">
                  <h3 class="font-semibold text-base-content mb-2">Lavash Features</h3>
                  <ul class="text-sm text-base-content/70 space-y-1">
                    <li>
                      &bull; Ash <code class="bg-base-200 px-1 rounded text-xs">form</code>
                      DSL for validation
                    </li>
                    <li>
                      &bull; <code class="bg-base-200 px-1 rounded text-xs">extend_errors</code>
                      for custom messages
                    </li>
                    <li>
                      &bull; <code class="bg-base-200 px-1 rounded text-xs">import_rx</code>
                      shared validators
                    </li>
                    <li>
                      &bull; Card type detection via
                      <code class="bg-base-200 px-1 rounded text-xs">rx()</code>
                    </li>
                    <li>
                      &bull; Real cart + orders shared with the
                      <a href="/storefront/checkout" class="link link-primary">store checkout</a>
                      via <code class="bg-base-200 px-1 rounded text-xs">Checkout.Shared</code>
                    </li>
                  </ul>
                </div>

                <div class="text-center">
                  <a href="/" class="text-primary hover:text-primary/80 text-sm">
                    &larr; Back to Demos
                  </a>
                </div>
              </aside>
            </div>
          <% end %>
        <% end %>

        <!-- Address Edit Modal -->
        <.lavash_component
          module={DemoWeb.Storefront.AddressEditModal}
          id="checkout-address-modal"
          open={@address_modal}
          actor={@current_user}
          bind={[open: :address_modal]}
        />
      </main>
    </div>
    """
  end
end
