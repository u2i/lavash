defmodule DemoWeb.Storefront.CheckoutLive do
  @moduledoc """
  Full checkout flow for the storefront.

  All logic (cart reads, totals, card validation, order placement)
  comes from `DemoWeb.Checkout.Shared`; the markup is composed from
  `DemoWeb.Checkout.Components`. `DemoWeb.CheckoutDemoLive` is the
  same checkout in Shopify-styled demo chrome.
  """
  use Lavash.LiveView
  use DemoWeb.Checkout.Shared

  # Top bar + container come from the shared store_page component
  # (flash from the live_session layout) — this template only
  # composes content. No :cart slot: checkout IS the cart.
  template do
    ~H"""
    <DemoWeb.Layouts.store_page current_user={@current_user}>
      <div class="space-y-6">
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
            <.empty_cart />
          <% else %>
            <div class="grid grid-cols-1 gap-6 lg:grid-cols-[1.6fr_1fr]">
              <!-- LEFT COLUMN -->
              <section class="card border border-base-300 bg-base-100 shadow-sm">
                <div class="card-body gap-6">
                  <div class="flex items-center justify-between">
                    <h1 class="text-2xl font-bold">Checkout</h1>
                    <a href={~p"/storefront/products"} class="link text-sm">
                      &larr; Back to shopping
                    </a>
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

              <!-- RIGHT COLUMN - Order Summary -->
              <aside class="lg:sticky lg:top-5 self-start space-y-4">
                <.order_summary
                  cart_items={@cart_items}
                  subtotal_display={@subtotal_display}
                  tax_display={@tax_display}
                  shipping_display={@shipping_display}
                  total_display={@total_display}
                />

                <.test_cards />
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
      </div>
    </DemoWeb.Layouts.store_page>
    """
  end
end
