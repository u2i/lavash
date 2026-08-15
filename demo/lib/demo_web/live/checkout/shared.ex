defmodule DemoWeb.Checkout.Shared do
  @moduledoc """
  Shared checkout logic for `DemoWeb.Storefront.CheckoutLive` and
  `DemoWeb.CheckoutDemoLive`.

  Both pages are the same checkout — real cart, real addresses, real
  order placement — differing only in chrome (store top bar vs the
  Shopify-styled demo shell). `use DemoWeb.Checkout.Shared` after
  `use Lavash.LiveView` injects everything below; the host module
  only declares its own template (composed from
  `DemoWeb.Checkout.Components`) and any page-specific extras.

  Injected DSL:

    * state — cart/user ids, payment params, UI state, placed order id
    * reads — cart items and addresses for the current user
    * form — the `Demo.Forms.Payment` validation form
    * calculates — cart totals, card-type detection, card validation
      (via `import_rx Demo.Validators.CreditCard`), address selection
    * actions — payment-method/UI toggles, address selection + modal,
      `place_order` / `pay_with_paypal`
    * mount — finds or creates the user's cart
  """

  defmacro __using__(_opts) do
    quote do
      import Lavash.Rx
      import Lavash.Optimistic.Components
      import Lavash.LiveView.Helpers, only: [lavash_component: 1]
      import DemoWeb.Checkout.Components

      require Logger

      # Credit card validators (expanded inline, transpiled to JS)
      import_rx Demo.Validators.CreditCard

      use Phoenix.VerifiedRoutes,
        endpoint: DemoWeb.Endpoint,
        router: DemoWeb.Router,
        statics: DemoWeb.static_paths()

      alias Demo.Cart.{Cart, CartItem}
      alias Demo.Forms.Payment
      alias Demo.Orders.{Address, Order}

      # ─────────────────────────────────────────────────────────────
      # State
      # ─────────────────────────────────────────────────────────────

      # Cart
      state :cart_id, :string, from: :ephemeral
      state :_user_id, :string, from: :ephemeral

      # `current_user` is injected by the on_mount hook. Declaring it
      # as state lets the template reference `@current_user` and rx()
      # see it (e.g. when passed as the AddressEditModal actor).
      state :current_user, :map, from: :assigns, assigns_key: :current_user

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
        invalidate :pubsub
      end

      # ─────────────────────────────────────────────────────────────
      # Payment Form (Ash form for validation)
      # ─────────────────────────────────────────────────────────────

      form :payment, Payment do
        create :pay
        skip_constraints([:card_number, :expiry, :cvv])
      end

      # ─────────────────────────────────────────────────────────────
      # Cart Calculations
      # ─────────────────────────────────────────────────────────────

      # optimistic: false — depends on @cart_items, a server-side Ash
      # read that never exists in client state; a client-side recompute
      # can only crash (undefined.length).
      calculate :is_empty, rx(@cart_items == nil or @cart_items == []), optimistic: false

      calculate :subtotal,
                rx(
                  Enum.reduce(@cart_items || [], Decimal.new("0.00"), fn item, acc ->
                    Decimal.add(acc, Decimal.mult(item.unit_price, item.quantity))
                  end)
                ),
                optimistic: false

      calculate :tax, rx(Decimal.mult(@subtotal, Decimal.new("0.08")) |> Decimal.round(2)),
        optimistic: false

      calculate :shipping,
                rx(
                  if Decimal.compare(@subtotal, Decimal.new("35.00")) == :lt,
                    do: Decimal.new("8.00"),
                    else: Decimal.new("0.00")
                ),
                optimistic: false

      calculate :total, rx(Decimal.add(Decimal.add(@subtotal, @tax), @shipping)),
        optimistic: false

      calculate :subtotal_display, rx("$" <> Decimal.to_string(@subtotal)), optimistic: false
      calculate :tax_display, rx("$" <> Decimal.to_string(@tax)), optimistic: false

      calculate :shipping_display,
                rx(
                  if Decimal.compare(@shipping, Decimal.new("0")) == :eq,
                    do: "Free",
                    else: "$" <> Decimal.to_string(@shipping)
                ),
                optimistic: false

      calculate :total_display, rx("$" <> Decimal.to_string(@total)), optimistic: false

      # ─────────────────────────────────────────────────────────────
      # Card Type Detection
      # ─────────────────────────────────────────────────────────────

      calculate :card_number_raw, rx(@payment_params["card_number"] || "")
      calculate :card_number_digits, rx(String.replace(@card_number_raw, ~r/\D/, ""))

      calculate :is_visa, rx(String.starts_with?(@card_number_digits, "4"))
      calculate :is_mastercard, rx(String.starts_with?(@card_number_digits, "5"))

      calculate :is_amex,
                rx(
                  String.starts_with?(@card_number_digits, "34") or
                    String.starts_with?(@card_number_digits, "37")
                )

      calculate :is_discover, rx(String.starts_with?(@card_number_digits, "6011"))
      calculate :has_card_type, rx(@is_visa or @is_mastercard or @is_amex or @is_discover)

      calculate :card_type_display,
                rx(
                  if @is_visa do
                    "Visa"
                  else
                    if @is_mastercard do
                      "Mastercard"
                    else
                      if @is_amex do
                        "American Express"
                      else
                        if @is_discover do
                          "Discover"
                        else
                          ""
                        end
                      end
                    end
                  end
                )

      calculate :show_visa, rx(@is_visa or not @has_card_type)
      calculate :show_mastercard, rx(@is_mastercard or not @has_card_type)
      calculate :show_amex, rx(@is_amex or not @has_card_type)
      calculate :show_discover, rx(@is_discover or not @has_card_type)

      # ─────────────────────────────────────────────────────────────
      # Card Validation (using imported defrx functions)
      # ─────────────────────────────────────────────────────────────

      calculate :card_number_valid,
                rx(
                  @payment_card_number_valid && valid_card_number?(@card_number_digits, @is_amex)
                )

      extend_errors :payment_card_number_errors do
        error(
          rx(!valid_card_number?(@card_number_digits, @is_amex) && @payment_card_number_valid),
          "Enter a valid card number"
        )
      end

      calculate :expiry_raw, rx(@payment_params["expiry"] || "")
      calculate :expiry_digits, rx(String.replace(@expiry_raw, ~r/\D/, ""))
      calculate :expiry_valid, rx(@payment_expiry_valid && valid_expiry?(@expiry_digits))

      extend_errors :payment_expiry_errors do
        error(
          rx(!valid_expiry?(@expiry_digits) && @payment_expiry_valid),
          "Enter a valid expiration date"
        )
      end

      calculate :cvv_raw, rx(@payment_params["cvv"] || "")
      calculate :cvv_digits, rx(String.replace(@cvv_raw, ~r/\D/, ""))
      calculate :cvv_valid, rx(@payment_cvv_valid && valid_cvv?(@cvv_digits, @is_amex))

      extend_errors :payment_cvv_errors do
        error(
          rx(!valid_cvv?(@cvv_digits, @is_amex) && @payment_cvv_valid),
          "Enter a valid security code"
        )
      end

      # ─────────────────────────────────────────────────────────────
      # Combined Validity
      # ─────────────────────────────────────────────────────────────

      calculate :card_form_valid,
                rx(@card_number_valid && @expiry_valid && @cvv_valid && @payment_name_valid)

      calculate :is_card_payment, rx(@payment_method == "card")
      calculate :form_valid, rx(if(@is_card_payment, do: @card_form_valid, else: true))

      # Address
      calculate :selected_address,
                rx(find_selected_address(@addresses, @selected_address_id)),
                optimistic: false

      def find_selected_address([], _), do: nil
      def find_selected_address(addresses, nil), do: List.first(addresses)

      def find_selected_address(addresses, id),
        do: Enum.find(addresses, List.first(addresses), &(&1.id == id))

      calculate :has_address, rx(@selected_address != nil), optimistic: false

      # optimistic: false — @has_address and @is_empty are server-side
      # calcs, so the client can never compute this correctly. The Pay
      # buttons are gated server-side via disabled={not @can_place}.
      calculate :can_place, rx(@form_valid and @has_address and not @is_empty), optimistic: false

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
          set :selected_address_id, & &1.params.id
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

        # `run` (not `effect`): effects receive a plain state map and
        # their return value is discarded, so an effect can neither
        # read socket.assigns nor put_state. `run` takes and returns
        # the socket.
        action :do_place_order do
          run fn socket ->
            DemoWeb.Checkout.Shared.place_order(socket, socket.assigns.payment_method)
          end
        end

        action :on_payment_error do
          run fn socket ->
            Phoenix.LiveView.put_flash(
              socket,
              :error,
              "Please check your payment details and try again."
            )
          end
        end

        action :pay_with_paypal do
          run fn socket -> DemoWeb.Checkout.Shared.place_order(socket, "paypal") end
        end
      end

      # ─────────────────────────────────────────────────────────────
      # Mount
      # ─────────────────────────────────────────────────────────────

      mount do
        run fn socket -> DemoWeb.Checkout.Shared.initialize_cart(socket) end
      end
    end
  end

  require Logger

  @doc """
  Creates an order from the current cart via `Demo.Orders.Order.:place`
  and records its id in `:order_placed_id` (or flashes on failure).
  """
  def place_order(socket, payment_method) do
    assigns = socket.assigns

    card_last_four =
      if payment_method == "card" do
        (assigns.card_number_digits || "") |> String.slice(-4, 4)
      end

    case Demo.Orders.Order
         |> Ash.Changeset.for_create(
           :place,
           %{
             cart_id: assigns.cart_id,
             subtotal: assigns.subtotal,
             tax: assigns.tax,
             shipping: assigns.shipping,
             total: assigns.total,
             payment_method: payment_method,
             card_last_four: card_last_four,
             shipping_address_id: assigns.selected_address && assigns.selected_address.id
           },
           actor: assigns.current_user
         )
         |> Ash.create() do
      {:ok, order} ->
        Lavash.Socket.put_state(socket, :order_placed_id, order.id)

      {:error, error} ->
        Logger.error("Order placement failed: #{inspect(error)}")

        Phoenix.LiveView.put_flash(
          socket,
          :error,
          "We couldn't place your order. Please try again."
        )
    end
  end

  @doc """
  Finds (or creates) the current user's cart and seeds `:cart_id` /
  `:_user_id` state. Runs from the shared `mount do` block.
  """
  def initialize_cart(socket) do
    user = socket.assigns[:current_user]

    cart_id =
      if user do
        case Demo.Cart.Cart
             |> Ash.Query.for_read(:for_user, %{user_id: user.id})
             |> Ash.read_one() do
          {:ok, nil} ->
            {:ok, cart} =
              Demo.Cart.Cart
              |> Ash.Changeset.for_create(:create, %{}, actor: user)
              |> Ash.create()

            cart.id

          {:ok, cart} ->
            cart.id

          _ ->
            nil
        end
      end

    socket
    |> Lavash.Socket.put_state(:cart_id, cart_id)
    |> Lavash.Socket.put_state(:_user_id, user && user.id)
  end
end
