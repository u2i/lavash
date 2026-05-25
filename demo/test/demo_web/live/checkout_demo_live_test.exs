defmodule DemoWeb.CheckoutDemoLiveTest do
  use DemoWeb.ConnCase
  import Phoenix.LiveViewTest

  describe "checkout demo" do
    test "renders payment + order summary", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/demos/checkout")
      assert html =~ "Credit card"
      assert html =~ "PayPal"
      assert html =~ "Pay now"
      assert html =~ "Test Card Numbers"
      assert html =~ "Bali Blue Moon"
    end

    test "switching payment method toggles state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/demos/checkout")

      html = view |> element("div[phx-click=select_paypal]") |> render_click()
      assert html =~ "is_card_payment"
      assert html =~ "Pay with PayPal"

      html = view |> element("div[phx-click=select_card]") |> render_click()
      refute html =~ "Pay with PayPal"
    end

    test "toggle_ship_to flips ship_to_expanded", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/demos/checkout")

      html = view |> element("button[phx-click=toggle_ship_to]") |> render_click()
      assert html =~ "ship_to_expanded"
    end
  end
end
