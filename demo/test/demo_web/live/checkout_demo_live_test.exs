defmodule DemoWeb.CheckoutDemoLiveTest do
  @moduledoc """
  The Shopify-style checkout demo is the real storefront checkout
  (`DemoWeb.Checkout.Shared`) in demo chrome — these tests cover the
  demo-specific pieces (seed button, chrome) plus one end-to-end
  order placement to prove the shared wiring holds on this route.
  """
  use DemoWeb.ConnCase
  import Phoenix.LiveViewTest

  @valid_card %{
    "card_number" => "4242 4242 4242 4242",
    "expiry" => "12/28",
    "cvv" => "123",
    "name" => "Test User"
  }

  # Drives a first regular request through the EnsureUser plug so an
  # anonymous user exists in the session, then returns {conn, user}.
  defp conn_with_user(conn) do
    conn = get(conn, "/demos/checkout")
    {conn, conn.assigns.current_user}
  end

  defp create_address(user) do
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
  end

  describe "checkout demo" do
    test "empty cart shows the seed button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/demos/checkout")

      assert html =~ "Your cart is empty"
      assert html =~ "Add sample items"
    end

    test "seeding the cart reveals the full checkout", %{conn: conn} do
      {conn, _user} = conn_with_user(conn)
      {:ok, view, _html} = live(conn, "/demos/checkout")

      view |> element("button", "Add sample items") |> render_click()

      # The seeded items come back via the pubsub invalidation the
      # create broadcast queued — re-render to process it.
      html = render(view)

      refute html =~ "Your cart is empty"
      assert html =~ "Credit card"
      assert html =~ "PayPal"
      assert html =~ "Test Card Numbers"
      # Seeds a sample product when the catalog is empty (test env)
      assert html =~ "Bali Blue Moon"
    end

    test "switching payment method toggles the PayPal button", %{conn: conn} do
      {conn, _user} = conn_with_user(conn)
      {:ok, view, _html} = live(conn, "/demos/checkout")

      view |> element("button", "Add sample items") |> render_click()
      render(view)

      html = view |> element("div[phx-click=select_paypal]") |> render_click()
      assert html =~ "Pay with PayPal"

      html = view |> element("div[phx-click=select_card]") |> render_click()
      refute html =~ "Pay with PayPal"
    end

    test "placing an order with a valid card creates a real order", %{conn: conn} do
      {conn, user} = conn_with_user(conn)
      create_address(user)

      {:ok, view, _html} = live(conn, "/demos/checkout")
      view |> element("button", "Add sample items") |> render_click()
      render(view)

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
    end
  end
end
