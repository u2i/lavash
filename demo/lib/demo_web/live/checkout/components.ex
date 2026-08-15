defmodule DemoWeb.Checkout.Components do
  @moduledoc """
  Markup shared by the storefront checkout and the Shopify-style
  checkout demo (both built on `DemoWeb.Checkout.Shared`).

  These are plain function components, so they bypass the Lavash
  template pipeline — every `data-lavash-*` annotation here is
  written out by hand (including the `data-lavash-display` span the
  pipeline would normally inject around `{@card_type_display}`). The
  annotation strings reference state-field names, which are identical
  in both host LiveViews because the state comes from the shared
  macro.
  """
  use Phoenix.Component

  import Lavash.Optimistic.Components, only: [input: 1]

  use Phoenix.VerifiedRoutes,
    endpoint: DemoWeb.Endpoint,
    router: DemoWeb.Router,
    statics: DemoWeb.static_paths()

  @doc """
  Order confirmation card shown once `@order_placed_id` is set.
  """
  attr :order_id, :string, required: true
  attr :subtotal_display, :string, required: true
  attr :tax_display, :string, required: true
  attr :shipping_display, :string, required: true
  attr :total_display, :string, required: true

  def order_placed(assigns) do
    ~H"""
    <div class="card border border-base-300 bg-base-100 shadow-sm max-w-lg mx-auto">
      <div class="card-body text-center">
        <div class="text-6xl mb-4 text-success">&#10003;</div>
        <h2 class="text-2xl font-bold mb-2">Order Placed!</h2>
        <p class="text-base-content/70 mb-2">
          Order <code class="bg-base-200 px-2 py-1 rounded">{String.slice(@order_id, 0, 8)}</code>
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
        <div class="flex gap-2 justify-center">
          <a href={~p"/storefront/products"} class="btn btn-ghost">Continue Shopping</a>
          <a href={~p"/account/orders/#{@order_id}"} class="btn btn-primary">View Order</a>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Empty-cart placeholder. The optional `:seed` slot renders extra
  actions (the demo page adds an "Add sample items" button so the
  checkout is exercisable without a shopping trip).
  """
  slot :seed

  def empty_cart(assigns) do
    ~H"""
    <div class="text-center py-16">
      <p class="text-lg text-base-content/60 mb-4">Your cart is empty</p>
      <div class="flex gap-2 justify-center">
        <a href={~p"/storefront/products"} class="btn btn-primary">Shop Coffees</a>
        {render_slot(@seed)}
      </div>
    </div>
    """
  end

  @doc """
  "Ship to" section: collapsible saved-address list with selection,
  per-address Edit buttons, and an add-address link. Drives the
  `toggle_ship_to`, `select_address`, `edit_address`, and
  `add_address` actions from `DemoWeb.Checkout.Shared`.
  """
  attr :addresses, :list, required: true
  attr :selected_address, :map, default: nil
  attr :ship_to_expanded, :boolean, required: true

  def ship_to(assigns) do
    ~H"""
    <div class="space-y-3">
      <div class="flex items-center justify-between">
        <div class="text-sm font-semibold">Ship to</div>
        <button phx-click="toggle_ship_to" class="btn btn-ghost btn-sm" aria-label="Toggle">
          <span
            data-lavash-visible="ship_to_expanded"
            class={if !@ship_to_expanded, do: "hidden"}
          >&#9652;</span>
          <span
            data-lavash-visible="ship_to_expanded"
            data-lavash-toggle="ship_to_expanded|hidden|"
            class={if @ship_to_expanded, do: "hidden"}
          >&#9662;</span>
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
              <input
                type="radio"
                name="address"
                class="radio radio-primary radio-sm"
                checked={@selected_address && @selected_address.id == address.id}
              />
              <div>
                <div class="font-semibold">
                  {address.first_name} {address.last_name}, {address.address}
                </div>
                <div class="text-sm opacity-70">
                  {address.city}, {address.state} {address.zip}
                </div>
              </div>
            </div>
            <button
              class="btn btn-ghost btn-sm text-base-content/70 hover:text-primary"
              phx-click="edit_address"
              phx-value-id={address.id}
            >
              Edit
            </button>
          </div>
        <% end %>
      </div>

      <a
        class="link link-primary inline-flex items-center gap-2 text-sm font-semibold cursor-pointer"
        phx-click="add_address"
      >
        <span class="text-lg leading-none">+</span> Add a new address
      </a>
    </div>
    """
  end

  @doc """
  Shipping cost summary row with the free-shipping threshold note.
  """
  attr :shipping_display, :string, required: true

  def shipping_method(assigns) do
    ~H"""
    <div class="space-y-3 border-t border-base-300 pt-6">
      <div class="flex items-center justify-between">
        <div class="text-sm font-semibold">Shipping</div>
        <div class="text-sm font-semibold">{@shipping_display}</div>
      </div>
      <p class="text-xs text-base-content/50">Free shipping on orders over $35</p>
    </div>
    """
  end

  @doc """
  Payment section: credit-card option with live card-type badges and
  the validated payment form, plus the PayPal option and its pay
  button. Submits `place_order` / `pay_with_paypal`.
  """
  attr :payment, :any, required: true, doc: "the AshPhoenix payment form"
  attr :payment_method, :string, required: true
  attr :use_shipping_as_billing, :boolean, required: true
  attr :can_place, :boolean, required: true
  attr :total, :any, required: true, doc: "order total as Decimal"
  attr :card_type_display, :string, required: true
  attr :has_card_type, :boolean, required: true
  attr :show_visa, :boolean, required: true
  attr :show_mastercard, :boolean, required: true
  attr :show_amex, :boolean, required: true
  attr :show_discover, :boolean, required: true
  attr :card_number_valid, :boolean, required: true
  attr :expiry_valid, :boolean, required: true
  attr :cvv_valid, :boolean, required: true
  attr :payment_name_valid, :boolean, required: true
  attr :payment_card_number_errors, :list, required: true
  attr :payment_expiry_errors, :list, required: true
  attr :payment_cvv_errors, :list, required: true
  attr :payment_name_errors, :list, required: true

  def payment_section(assigns) do
    ~H"""
    <div class="space-y-4 border-t border-base-300 pt-6">
      <div>
        <div class="text-2xl font-bold">Payment</div>
        <div class="text-sm opacity-70">All transactions are secure and encrypted.</div>
      </div>

      <!-- Credit Card Option -->
      <div
        class="rounded-lg border border-base-300 p-4 cursor-pointer transition-all"
        data-lavash-toggle="is_card_payment|border-primary ring-1 ring-primary|border-base-300"
      >
        <div class="flex items-center gap-3 cursor-pointer" phx-click="select_card">
          <input
            type="radio"
            name="payment_method"
            class="radio radio-primary"
            checked={@payment_method == "card"}
          />
          <span class="font-semibold">Credit card</span>
          <span class="ml-auto flex items-center gap-1">
            <span
              data-lavash-visible="has_card_type"
              class={"text-sm font-medium text-primary" <> unless @has_card_type, do: " hidden", else: ""}
            ><span data-lavash-display="card_type_display">{@card_type_display}</span></span>
            <span
              data-lavash-visible="show_visa"
              class={"badge badge-outline badge-sm" <> unless @show_visa, do: " hidden", else: ""}
            >VISA</span>
            <span
              data-lavash-visible="show_mastercard"
              class={"badge badge-outline badge-sm" <> unless @show_mastercard, do: " hidden", else: ""}
            >MC</span>
            <span
              data-lavash-visible="show_amex"
              class={"badge badge-outline badge-sm" <> unless @show_amex, do: " hidden", else: ""}
            >AMEX</span>
            <span
              data-lavash-visible="show_discover"
              class={"badge badge-outline badge-sm" <> unless @show_discover, do: " hidden", else: ""}
            >DISC</span>
          </span>
        </div>

        <.form
          for={@payment}
          id="payment-form"
          phx-change="validate_payment"
          phx-submit="place_order"
          data-lavash-visible="is_card_payment"
          class={"mt-4 space-y-3" <> if @payment_method != "card", do: " hidden", else: ""}
        >
          <.input
            field={@payment[:card_number]}
            label="Card number"
            valid={@card_number_valid}
            valid_field="card_number_valid"
            errors={@payment_card_number_errors}
            autocomplete="cc-number"
            inputmode="numeric"
            format="credit-card"
          />

          <div class="grid grid-cols-2 gap-3">
            <.input
              field={@payment[:expiry]}
              label="Expiration (MM/YY)"
              valid={@expiry_valid}
              valid_field="expiry_valid"
              errors={@payment_expiry_errors}
              autocomplete="cc-exp"
              inputmode="numeric"
              maxlength="5"
              format="expiry"
            />
            <.input
              field={@payment[:cvv]}
              label="Security code"
              valid={@cvv_valid}
              valid_field="cvv_valid"
              errors={@payment_cvv_errors}
              autocomplete="cc-csc"
              inputmode="numeric"
              maxlength="4"
            />
          </div>

          <.input
            field={@payment[:name]}
            label="Name on card"
            valid={@payment_name_valid}
            errors={@payment_name_errors}
            autocomplete="cc-name"
          />

          <label class="flex items-center gap-3 cursor-pointer pt-1">
            <input
              type="checkbox"
              class="checkbox checkbox-sm"
              checked={@use_shipping_as_billing}
              phx-click="toggle_billing_address"
            />
            <span class="text-sm">Use shipping address as billing address</span>
          </label>

          <button
            type="submit"
            disabled={not @can_place}
            class={"btn btn-lg w-full " <> if @can_place, do: "btn-primary", else: "btn-disabled"}
          >
            Pay ${Decimal.to_string(@total)}
          </button>
        </.form>
      </div>

      <!-- PayPal Option -->
      <div
        class="flex items-center gap-3 rounded-lg border p-4 cursor-pointer transition-all"
        phx-click="select_paypal"
        data-lavash-toggle="is_card_payment|border-base-300|border-primary ring-1 ring-primary"
      >
        <input
          type="radio"
          name="payment_method"
          class="radio radio-primary"
          checked={@payment_method == "paypal"}
        />
        <span class="font-semibold">PayPal</span>
        <span class="ml-auto text-sm font-bold">
          <span class="text-[#003087]">Pay</span><span class="text-[#009cde]">Pal</span>
        </span>
      </div>

      <%= if @payment_method == "paypal" do %>
        <button
          phx-click="pay_with_paypal"
          disabled={not @can_place}
          class={"btn btn-lg w-full " <> if @can_place, do: "btn-primary", else: "btn-disabled"}
        >
          Pay with PayPal
        </button>
      <% end %>
    </div>
    """
  end

  @doc """
  Order summary card: cart line items and totals.
  """
  attr :cart_items, :list, required: true
  attr :subtotal_display, :string, required: true
  attr :tax_display, :string, required: true
  attr :shipping_display, :string, required: true
  attr :total_display, :string, required: true

  def order_summary(assigns) do
    ~H"""
    <section class="card border border-base-300 bg-base-100 shadow-sm">
      <div class="card-body gap-5">
        <%= for item <- @cart_items || [] do %>
          <div class="flex items-start gap-4">
            <div class="relative">
              <div class="avatar">
                <div class="w-14 rounded-lg bg-base-200 flex items-center justify-center">
                  <svg viewBox="0 0 24 24" class="h-8 w-8 opacity-40" fill="none">
                    <path
                      d="M7 7h10v14H7V7Z"
                      stroke="currentColor"
                      stroke-width="1.5"
                      stroke-linejoin="round"
                    />
                    <path
                      d="M9 7V5h6v2"
                      stroke="currentColor"
                      stroke-width="1.5"
                      stroke-linecap="round"
                    />
                  </svg>
                </div>
              </div>
              <div class="badge badge-neutral badge-sm absolute -right-2 -top-2">
                {item.quantity}
              </div>
            </div>
            <div class="flex-1">
              <div class="font-bold">{item.product.name}</div>
              <div class="text-sm opacity-70">{item.product.origin}</div>
            </div>
            <div class="text-sm font-bold">
              ${Decimal.to_string(Decimal.mult(item.unit_price, item.quantity))}
            </div>
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
    """
  end

  @doc """
  Test card number reference box.
  """
  def test_cards(assigns) do
    ~H"""
    <div class="p-4 bg-base-100 rounded-lg border border-base-300">
      <h3 class="font-semibold text-base-content mb-2">Test Card Numbers</h3>
      <ul class="text-sm text-base-content/70 space-y-1 font-mono">
        <li><span class="text-base-content font-semibold">Visa:</span> 4242 4242 4242 4242</li>
        <li><span class="text-base-content font-semibold">MC:</span> 5555 5555 5555 4444</li>
        <li><span class="text-base-content font-semibold">Amex:</span> 3782 822463 10005</li>
        <li><span class="text-base-content font-semibold">Disc:</span> 6011 1111 1111 1117</li>
      </ul>
      <p class="text-xs text-base-content/50 mt-2">
        Use any future date and any 3-4 digit CVV
      </p>
    </div>
    """
  end
end
