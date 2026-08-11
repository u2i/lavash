defmodule DemoWeb.Storefront.CheckoutLiveTest do
  use DemoWeb.ConnCase
  import Phoenix.LiveViewTest

  @valid_card %{
    "card_number" => "4242 4242 4242 4242",
    "expiry" => "12/28",
    "cvv" => "123",
    "name" => "Test User"
  }

  # Sandbox ownership comes from DemoWeb.ConnCase.

  # Drives a first regular request through the EnsureUser plug so an
  # anonymous user exists in the session, then returns {conn, user}.
  defp conn_with_user(conn) do
    conn = get(conn, "/storefront/checkout")
    {conn, conn.assigns.current_user}
  end

  defp seed_cart_and_address(user) do
    product =
      Demo.Catalog.Product
      |> Ash.Changeset.for_create(:create, %{name: "Test Beans", price: Decimal.new("20.00")})
      |> Ash.create!()

    # The dead render of the first request already ran mount and created
    # a cart for the user — reuse it (a second cart would break the
    # LiveView's read_one lookup).
    cart =
      case Demo.Cart.Cart
           |> Ash.Query.for_read(:for_user, %{user_id: user.id})
           |> Ash.read_one!() do
        nil ->
          Demo.Cart.Cart
          |> Ash.Changeset.for_create(:create, %{}, actor: user)
          |> Ash.create!()

        cart ->
          cart
      end

    Demo.Cart.CartItem
    |> Ash.Changeset.for_create(:create_row, %{
      cart_id: cart.id,
      product_id: product.id,
      quantity: 2
    })
    |> Ash.create!()

    Demo.Orders.Address
    |> Ash.Changeset.for_create(
      :save,
      %{
        first_name: "Test",
        last_name: "User",
        address: "1 Main St",
        city: "Springfield",
        state: "IL",
        zip: "62701"
      },
      actor: user
    )
    |> Ash.create!()

    cart
  end

  describe "storefront checkout" do
    test "mounts (empty cart redirects or renders empty state)", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/storefront/checkout")
      # Empty cart: page mounts; we just sanity-check the lavash root is present
      assert html =~ "lavash-optimistic-root"
    end

    test "placing an order with a valid card shows confirmation and creates the order",
         %{conn: conn} do
      {conn, user} = conn_with_user(conn)
      cart = seed_cart_and_address(user)

      {:ok, view, html} = live(conn, "/storefront/checkout")
      refute html =~ "Your cart is empty"

      view
      |> form("#payment-form", payment: @valid_card)
      |> render_change()

      html =
        view
        |> form("#payment-form", payment: @valid_card)
        |> render_submit()

      assert html =~ "Order Placed!"

      [order] =
        Demo.Orders.Order
        |> Ash.Query.for_read(:for_user, %{user_id: user.id})
        |> Ash.read!()

      assert order.payment_method == "card"
      assert order.card_last_four == "4242"

      order = Ash.load!(order, :items)
      assert [%{quantity: 2, product_name: "Test Beans"}] = order.items

      # Placing the order empties the cart
      assert Demo.Cart.CartItem
             |> Ash.Query.for_read(:for_cart, %{cart_id: cart.id})
             |> Ash.read!() == []
    end

    test "submitting invalid payment details surfaces an error instead of failing silently",
         %{conn: conn} do
      {conn, user} = conn_with_user(conn)
      seed_cart_and_address(user)

      {:ok, view, _html} = live(conn, "/storefront/checkout")

      html =
        view
        |> form("#payment-form", payment: %{"card_number" => "", "expiry" => "", "cvv" => ""})
        |> render_submit()

      assert html =~ "Please check your payment details"

      assert Demo.Orders.Order
             |> Ash.Query.for_read(:for_user, %{user_id: user.id})
             |> Ash.read!() == []
    end

    test "Pay button is disabled until the card form is valid", %{conn: conn} do
      {conn, user} = conn_with_user(conn)
      seed_cart_and_address(user)

      {:ok, view, html} = live(conn, "/storefront/checkout")

      # can_place is false before card details are entered
      assert html =~ "btn-disabled"

      html =
        view
        |> form("#payment-form", payment: @valid_card)
        |> render_change()

      refute html =~ "btn-disabled"
    end
  end
end
