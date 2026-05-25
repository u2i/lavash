defmodule DemoWeb.Storefront.CheckoutLive do
  @moduledoc """
  Full checkout flow for the storefront.

  Reads from the real cart, validates payment with all Lavash features
  (forms, extend_errors, import_rx, optimistic card detection), and
  creates an order backed by SQLite.
  """
  use Lavash.LiveView
  import Lavash.Rx
  import Lavash.LiveView.Components
  import Lavash.LiveView.Helpers, only: [lavash_component: 1]

  # Import credit card validators (expanded inline, transpiled to JS)
  import_rx Demo.Validators.CreditCard

  use Phoenix.VerifiedRoutes,
    endpoint: DemoWeb.Endpoint,
    router: DemoWeb.Router,
    statics: DemoWeb.static_paths()

  alias Demo.Cart.{Cart, CartItem}
  alias Demo.Orders.{Order, Address}
  alias Demo.Forms.Payment

  # ─────────────────────────────────────────────────────────────
  # State
  # ─────────────────────────────────────────────────────────────

  # Cart
  state :cart_id, :string, from: :ephemeral
  state :_user_id, :string, from: :ephemeral

  # Payment form params
  state :payment_params, :map, from: :ephemeral, default: %{}, optimistic: true

  # UI state
  state :payment_method, :string, from: :ephemeral, default: "card", optimistic: true
  state :use_shipping_as_billing, :boolean, from: :ephemeral, default: true, optimistic: true
  state :ship_to_expanded, :boolean, from: :ephemeral, default: true, optimistic: true
  state :selected_address_id, :string, from: :ephemeral, default: nil, optimistic: true
  state :address_modal, :any, from: :ephemeral, default: nil, optimistic: true

  # Order result
  state :order_placed_id, :string, from: :ephemeral, default: nil

  # ─────────────────────────────────────────────────────────────
  # Reads
  # ─────────────────────────────────────────────────────────────

  read :cart_items, CartItem, :for_cart do
    argument :cart_id, state(:cart_id)
    async false
    invalidate :pubsub
  end

  read :addresses, Address, :for_user do
    argument :user_id, state(:_user_id)
    async false
  end

  # ─────────────────────────────────────────────────────────────
  # Payment Form (Ash form for validation)
  # ─────────────────────────────────────────────────────────────

  form :payment, Payment do
    create :pay
    skip_constraints [:card_number, :expiry, :cvv]
  end

  # ─────────────────────────────────────────────────────────────
  # Cart Calculations
  # ─────────────────────────────────────────────────────────────

  calculate :is_empty, rx(@cart_items == nil or @cart_items == [])

  calculate :subtotal,
            rx(
              Enum.reduce(@cart_items || [], Decimal.new("0.00"), fn item, acc ->
                Decimal.add(acc, Decimal.mult(item.unit_price, item.quantity))
              end)
            ),
            optimistic: false

  calculate :tax, rx(Decimal.mult(@subtotal, Decimal.new("0.08")) |> Decimal.round(2)), optimistic: false

  calculate :shipping,
            rx(if Decimal.compare(@subtotal, Decimal.new("35.00")) == :lt, do: Decimal.new("8.00"), else: Decimal.new("0.00")),
            optimistic: false

  calculate :total, rx(Decimal.add(Decimal.add(@subtotal, @tax), @shipping)), optimistic: false

  calculate :subtotal_display, rx("$" <> Decimal.to_string(@subtotal)), optimistic: false
  calculate :tax_display, rx("$" <> Decimal.to_string(@tax)), optimistic: false
  calculate :shipping_display, rx(if Decimal.compare(@shipping, Decimal.new("0")) == :eq, do: "Free", else: "$" <> Decimal.to_string(@shipping)), optimistic: false
  calculate :total_display, rx("$" <> Decimal.to_string(@total)), optimistic: false

  # ─────────────────────────────────────────────────────────────
  # Card Type Detection
  # ─────────────────────────────────────────────────────────────

  calculate :card_number_raw, rx(@payment_params["card_number"] || "")
  calculate :card_number_digits, rx(String.replace(@card_number_raw, ~r/\D/, ""))

  calculate :is_visa, rx(String.starts_with?(@card_number_digits, "4"))
  calculate :is_mastercard, rx(String.starts_with?(@card_number_digits, "5"))
  calculate :is_amex, rx(String.starts_with?(@card_number_digits, "34") or String.starts_with?(@card_number_digits, "37"))
  calculate :is_discover, rx(String.starts_with?(@card_number_digits, "6011"))
  calculate :has_card_type, rx(@is_visa or @is_mastercard or @is_amex or @is_discover)

  calculate :card_type_display,
    rx(
      if @is_visa do "Visa"
      else if @is_mastercard do "Mastercard"
      else if @is_amex do "American Express"
      else if @is_discover do "Discover"
      else "" end end end end
    )

  calculate :show_visa, rx(@is_visa or not @has_card_type)
  calculate :show_mastercard, rx(@is_mastercard or not @has_card_type)
  calculate :show_amex, rx(@is_amex or not @has_card_type)
  calculate :show_discover, rx(@is_discover or not @has_card_type)

  # ─────────────────────────────────────────────────────────────
  # Card Validation (using imported defrx functions)
  # ─────────────────────────────────────────────────────────────

  calculate :card_number_valid,
    rx(@payment_card_number_valid && valid_card_number?(@card_number_digits, @is_amex))

  extend_errors :payment_card_number_errors do
    error rx(!valid_card_number?(@card_number_digits, @is_amex) && @payment_card_number_valid),
      "Enter a valid card number"
  end

  calculate :expiry_raw, rx(@payment_params["expiry"] || "")
  calculate :expiry_digits, rx(String.replace(@expiry_raw, ~r/\D/, ""))
  calculate :expiry_valid, rx(@payment_expiry_valid && valid_expiry?(@expiry_digits))

  extend_errors :payment_expiry_errors do
    error rx(!valid_expiry?(@expiry_digits) && @payment_expiry_valid),
      "Enter a valid expiration date"
  end

  calculate :cvv_raw, rx(@payment_params["cvv"] || "")
  calculate :cvv_digits, rx(String.replace(@cvv_raw, ~r/\D/, ""))
  calculate :cvv_valid, rx(@payment_cvv_valid && valid_cvv?(@cvv_digits, @is_amex))

  extend_errors :payment_cvv_errors do
    error rx(!valid_cvv?(@cvv_digits, @is_amex) && @payment_cvv_valid),
      "Enter a valid security code"
  end

  # ─────────────────────────────────────────────────────────────
  # Combined Validity
  # ─────────────────────────────────────────────────────────────

  calculate :card_form_valid, rx(@card_number_valid && @expiry_valid && @cvv_valid && @payment_name_valid)
  calculate :is_card_payment, rx(@payment_method == "card")
  calculate :form_valid, rx(if(@is_card_payment, do: @card_form_valid, else: true))

  # Address
  calculate :selected_address,
            rx(find_selected_address(@addresses, @selected_address_id)),
            optimistic: false

  def find_selected_address([], _), do: nil
  def find_selected_address(addresses, nil), do: List.first(addresses)
  def find_selected_address(addresses, id), do: Enum.find(addresses, List.first(addresses), &(&1.id == id))

  calculate :has_address, rx(@selected_address != nil), optimistic: false
  calculate :can_place, rx(@form_valid and @has_address and not @is_empty)

  # ─────────────────────────────────────────────────────────────
  # Actions
  # ─────────────────────────────────────────────────────────────

  actions do
    action :select_card do
      set :payment_method, "card"
    end

    action :select_paypal do
      set :payment_method, "paypal"
    end

    action :toggle_billing_address do
      set :use_shipping_as_billing, rx(not @use_shipping_as_billing)
    end

    action :toggle_ship_to do
      set :ship_to_expanded, rx(not @ship_to_expanded)
    end

    action :select_address, [:id] do
      set :selected_address_id, &(&1.params.id)
    end

    action :add_address do
      set :address_modal, :create
    end

    action :edit_address, [:id] do
      set :address_modal, rx({:edit, @id})
    end

    action :place_order do
      submit :payment, on_success: :do_place_order, on_error: :on_payment_error
    end

    action :do_place_order do
      effect fn state ->
        user = state.assigns.current_user
        assigns = state.assigns

        card_last_four =
          (assigns.card_number_digits || "")
          |> String.slice(-4, 4)

        case Order
             |> Ash.Changeset.for_create(:place, %{
               cart_id: assigns.cart_id,
               subtotal: assigns.subtotal,
               tax: assigns.tax,
               shipping: assigns.shipping,
               total: assigns.total,
               payment_method: assigns.payment_method,
               card_last_four: card_last_four,
               shipping_address_id: assigns.selected_address && assigns.selected_address.id
             }, actor: user)
             |> Ash.create() do
          {:ok, order} ->
            Lavash.Socket.put_state(state, :order_placed_id, order.id)

          {:error, _} ->
            state
        end
      end
    end

    action :on_payment_error do
      # Form errors displayed via Ash form validation
    end

    action :pay_with_paypal do
      effect fn state ->
        user = state.assigns.current_user
        assigns = state.assigns

        case Order
             |> Ash.Changeset.for_create(:place, %{
               cart_id: assigns.cart_id,
               subtotal: assigns.subtotal,
               tax: assigns.tax,
               shipping: assigns.shipping,
               total: assigns.total,
               payment_method: "paypal",
               shipping_address_id: assigns.selected_address && assigns.selected_address.id
             }, actor: user)
             |> Ash.create() do
          {:ok, order} ->
            Lavash.Socket.put_state(state, :order_placed_id, order.id)

          {:error, _} ->
            state
        end
      end
    end
  end

  # ─────────────────────────────────────────────────────────────
  # Mount
  # ─────────────────────────────────────────────────────────────

  def on_mount(socket) do
    user = socket.assigns[:current_user]

    cart_id =
      if user do
        case Cart |> Ash.Query.for_read(:for_user, %{user_id: user.id}) |> Ash.read_one() do
          {:ok, nil} ->
            # Create cart if none exists
            {:ok, cart} =
              Cart
              |> Ash.Changeset.for_create(:create, %{}, actor: user)
              |> Ash.create()

            cart.id

          {:ok, cart} ->
            cart.id

          _ ->
            nil
        end
      end

    socket =
      socket
      |> Lavash.Socket.put_state(:cart_id, cart_id)
      |> Lavash.Socket.put_state(:_user_id, user && user.id)

    {:ok, socket}
  end

  # ─────────────────────────────────────────────────────────────
  # Template
  # ─────────────────────────────────────────────────────────────

  render fn assigns ->
    ~L"""
    <div class="bg-base-200 min-h-screen">
      <main class="mx-auto max-w-6xl p-4 lg:p-8">
        <%= if @order_placed_id do %>
          <div class="card border border-base-300 bg-base-100 shadow-sm max-w-lg mx-auto">
            <div class="card-body text-center">
              <div class="text-6xl mb-4 text-success">&#10003;</div>
              <h2 class="text-2xl font-bold mb-2">Order Placed!</h2>
              <p class="text-base-content/70 mb-2">
                Order <code class="bg-base-200 px-2 py-1 rounded">{String.slice(@order_placed_id, 0, 8)}</code>
              </p>
              <div class="bg-base-200 rounded-xl p-4 mb-4">
                <div class="flex justify-between mb-2">
                  <span>Subtotal</span>
                  <span>{@subtotal_display}</span>
                </div>
                <div class="flex justify-between mb-2">
                  <span>Tax</span>
                  <span>{@tax_display}</span>
                </div>
                <div class="flex justify-between mb-2">
                  <span>Shipping</span>
                  <span>{@shipping_display}</span>
                </div>
                <div class="divider my-2"></div>
                <div class="flex justify-between font-bold text-lg">
                  <span>Total</span>
                  <span>{@total_display}</span>
                </div>
              </div>
              <a href={~p"/storefront/products"} class="btn btn-primary">Continue Shopping</a>
            </div>
          </div>
        <% else %>
          <%= if @is_empty do %>
            <div class="text-center py-16">
              <p class="text-lg text-base-content/60 mb-4">Your cart is empty</p>
              <a href={~p"/storefront/products"} class="btn btn-primary">Shop Coffees</a>
            </div>
          <% else %>
            <div class="grid grid-cols-1 gap-6 lg:grid-cols-[1.6fr_1fr]">
              <!-- LEFT COLUMN -->
              <section class="card border border-base-300 bg-base-100 shadow-sm">
                <div class="card-body gap-6">
                  <!-- Header -->
                  <div class="flex items-center justify-between">
                    <h1 class="text-2xl font-bold">Checkout</h1>
                    <a href={~p"/storefront/products"} class="link text-sm">&larr; Back to shopping</a>
                  </div>

                  <!-- Ship to -->
                  <div class="space-y-3">
                    <div class="flex items-center justify-between">
                      <div class="text-sm font-semibold">Ship to</div>
                      <button phx-click="toggle_ship_to" class="btn btn-ghost btn-sm" aria-label="Toggle">
                        <span data-lavash-visible="ship_to_expanded" class={unless @ship_to_expanded, do: "hidden"}>&#9652;</span>
                        <span data-lavash-visible="ship_to_expanded" data-lavash-toggle="ship_to_expanded|hidden|" class={if @ship_to_expanded, do: "hidden"}>&#9662;</span>
                      </button>
                    </div>

                    <div
                      data-lavash-visible="ship_to_expanded"
                      class={"space-y-2" <> unless @ship_to_expanded, do: " hidden", else: ""}
                    >
                      <%= for address <- @addresses do %>
                        <div
                          class={"flex items-start justify-between rounded-lg border p-4 cursor-pointer transition-all " <>
                            if @selected_address && @selected_address.id == address.id do
                              "border-primary ring-1 ring-primary bg-base-200/40"
                            else
                              "border-base-300 hover:border-base-400"
                            end}
                          phx-click="select_address"
                          phx-value-id={address.id}
                        >
                          <div class="flex items-center gap-3">
                            <input type="radio" name="address" class="radio radio-primary radio-sm"
                              checked={@selected_address && @selected_address.id == address.id} />
                            <div>
                              <div class="font-semibold">{address.first_name} {address.last_name}, {address.address}</div>
                              <div class="text-sm opacity-70">{address.city}, {address.state} {address.zip}</div>
                            </div>
                          </div>
                          <button class="btn btn-ghost btn-sm text-base-content/70 hover:text-primary"
                            phx-click="edit_address" phx-value-id={address.id}>Edit</button>
                        </div>
                      <% end %>
                    </div>

                    <a class="link link-primary inline-flex items-center gap-2 text-sm font-semibold cursor-pointer"
                      phx-click="add_address">
                      <span class="text-lg leading-none">+</span> Add a new address
                    </a>
                  </div>

                  <!-- Shipping method -->
                  <div class="space-y-3 border-t border-base-300 pt-6">
                    <div class="flex items-center justify-between">
                      <div class="text-sm font-semibold">Shipping</div>
                      <div class="text-sm font-semibold">{@shipping_display}</div>
                    </div>
                    <p class="text-xs text-base-content/50">Free shipping on orders over $35</p>
                  </div>

                  <!-- Payment -->
                  <div class="space-y-4 border-t border-base-300 pt-6">
                    <div>
                      <div class="text-2xl font-bold">Payment</div>
                      <div class="text-sm opacity-70">All transactions are secure and encrypted.</div>
                    </div>

                    <!-- Credit Card Option -->
                    <div class="rounded-lg border border-base-300 p-4 cursor-pointer transition-all"
                      data-lavash-toggle="is_card_payment|border-primary ring-1 ring-primary|border-base-300">
                      <div class="flex items-center gap-3 cursor-pointer" phx-click="select_card">
                        <input type="radio" name="payment_method" class="radio radio-primary"
                          checked={@payment_method == "card"} />
                        <span class="font-semibold">Credit card</span>
                        <span class="ml-auto flex items-center gap-1">
                          <span data-lavash-visible="has_card_type"
                            class={"text-sm font-medium text-primary" <> unless @has_card_type, do: " hidden", else: ""}
                          >{@card_type_display}</span>
                          <span data-lavash-visible="show_visa" class={"badge badge-outline badge-sm" <> unless @show_visa, do: " hidden", else: ""}>VISA</span>
                          <span data-lavash-visible="show_mastercard" class={"badge badge-outline badge-sm" <> unless @show_mastercard, do: " hidden", else: ""}>MC</span>
                          <span data-lavash-visible="show_amex" class={"badge badge-outline badge-sm" <> unless @show_amex, do: " hidden", else: ""}>AMEX</span>
                          <span data-lavash-visible="show_discover" class={"badge badge-outline badge-sm" <> unless @show_discover, do: " hidden", else: ""}>DISC</span>
                        </span>
                      </div>

                      <.form for={@payment} id="payment-form" phx-change="validate_payment" phx-submit="place_order"
                        data-lavash-visible="is_card_payment"
                        class={"mt-4 space-y-3" <> if @payment_method != "card", do: " hidden", else: ""}>
                        <.input field={@payment[:card_number]} label="Card number"
                          valid={@card_number_valid} valid_field="card_number_valid"
                          errors={@payment_card_number_errors}
                          autocomplete="cc-number" inputmode="numeric" format="credit-card" />

                        <div class="grid grid-cols-2 gap-3">
                          <.input field={@payment[:expiry]} label="Expiration (MM/YY)"
                            valid={@expiry_valid} valid_field="expiry_valid"
                            errors={@payment_expiry_errors}
                            autocomplete="cc-exp" inputmode="numeric" maxlength="5" format="expiry" />
                          <.input field={@payment[:cvv]} label="Security code"
                            valid={@cvv_valid} valid_field="cvv_valid"
                            errors={@payment_cvv_errors}
                            autocomplete="cc-csc" inputmode="numeric" maxlength="4" />
                        </div>

                        <.input field={@payment[:name]} label="Name on card"
                          valid={@payment_name_valid} errors={@payment_name_errors}
                          autocomplete="cc-name" />

                        <label class="flex items-center gap-3 cursor-pointer pt-1">
                          <input type="checkbox" class="checkbox checkbox-sm"
                            checked={@use_shipping_as_billing} phx-click="toggle_billing_address" />
                          <span class="text-sm">Use shipping address as billing address</span>
                        </label>

                        <button type="submit" data-lavash-enabled="form_valid" class="btn btn-lg w-full"
                          data-lavash-toggle="form_valid|btn-primary|btn-disabled">
                          Pay ${Decimal.to_string(@total)}
                        </button>
                      </.form>
                    </div>

                    <!-- PayPal Option -->
                    <div class="flex items-center gap-3 rounded-lg border p-4 cursor-pointer transition-all"
                      phx-click="select_paypal"
                      data-lavash-toggle="is_card_payment|border-base-300|border-primary ring-1 ring-primary">
                      <input type="radio" name="payment_method" class="radio radio-primary"
                        checked={@payment_method == "paypal"} />
                      <span class="font-semibold">PayPal</span>
                      <span class="ml-auto text-sm font-bold">
                        <span class="text-[#003087]">Pay</span><span class="text-[#009cde]">Pal</span>
                      </span>
                    </div>

                    <%= if @payment_method == "paypal" do %>
                      <button phx-click="pay_with_paypal" class="btn btn-lg w-full btn-primary">
                        Pay with PayPal
                      </button>
                    <% end %>
                  </div>
                </div>
              </section>

              <!-- RIGHT COLUMN - Order Summary -->
              <aside class="lg:sticky lg:top-5 self-start space-y-4">
                <section class="card border border-base-300 bg-base-100 shadow-sm">
                  <div class="card-body gap-5">
                    <!-- Cart items -->
                    <%= for item <- @cart_items || [] do %>
                      <div class="flex items-start gap-4">
                        <div class="relative">
                          <div class="avatar">
                            <div class="w-14 rounded-lg bg-base-200 flex items-center justify-center">
                              <svg viewBox="0 0 24 24" class="h-8 w-8 opacity-40" fill="none">
                                <path d="M7 7h10v14H7V7Z" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round" />
                                <path d="M9 7V5h6v2" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" />
                              </svg>
                            </div>
                          </div>
                          <div class="badge badge-neutral badge-sm absolute -right-2 -top-2">{item.quantity}</div>
                        </div>
                        <div class="flex-1">
                          <div class="font-bold">{item.product.name}</div>
                          <div class="text-sm opacity-70">{item.product.origin}</div>
                        </div>
                        <div class="text-sm font-bold">${Decimal.to_string(Decimal.mult(item.unit_price, item.quantity))}</div>
                      </div>
                    <% end %>

                    <!-- Totals -->
                    <div class="space-y-2 border-t border-base-300 pt-4">
                      <div class="flex items-center justify-between">
                        <span class="opacity-80">Subtotal</span>
                        <span>{@subtotal_display}</span>
                      </div>
                      <div class="flex items-center justify-between">
                        <span class="opacity-80">Tax (8%)</span>
                        <span>{@tax_display}</span>
                      </div>
                      <div class="flex items-center justify-between">
                        <span class="opacity-80">Shipping</span>
                        <span>{@shipping_display}</span>
                      </div>
                      <div class="divider my-2"></div>
                      <div class="flex items-end justify-between">
                        <div class="text-lg font-bold">Total</div>
                        <div class="flex items-baseline gap-2">
                          <div class="text-xs opacity-60">USD</div>
                          <div class="text-2xl font-bold">{@total_display}</div>
                        </div>
                      </div>
                    </div>
                  </div>
                </section>

                <!-- Test Card Numbers -->
                <div class="p-4 bg-base-100 rounded-lg border border-base-300">
                  <h3 class="font-semibold text-base-content mb-2">Test Card Numbers</h3>
                  <ul class="text-sm text-base-content/70 space-y-1 font-mono">
                    <li><span class="text-base-content font-semibold">Visa:</span> 4242 4242 4242 4242</li>
                    <li><span class="text-base-content font-semibold">MC:</span> 5555 5555 5555 4444</li>
                    <li><span class="text-base-content font-semibold">Amex:</span> 3782 822463 10005</li>
                    <li><span class="text-base-content font-semibold">Disc:</span> 6011 1111 1111 1117</li>
                  </ul>
                  <p class="text-xs text-base-content/50 mt-2">Use any future date and any 3-4 digit CVV</p>
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
          bind={[open: :address_modal]}
          current_user={@current_user}
        />
      </main>
    </div>
    """
  end
end
