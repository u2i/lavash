defmodule DemoWeb.StorefrontLiveTest do
  use DemoWeb.ConnCase
  import Phoenix.LiveViewTest

  alias Demo.Cart.CartItem
  alias Demo.Catalog.Product

  defp create_product! do
    Product
    |> Ash.Changeset.for_create(:create, %{
      name: "Landing Beans",
      origin: "Kenya",
      price: Decimal.new("18.00"),
      in_stock: true
    })
    |> Ash.create!()
  end

  describe "storefront landing" do
    test "mounts as a lavash view with the cart flyover", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/storefront")

      assert html =~ "lavash-optimistic-root"
      # The flyover trigger (icon + badge) renders — the page has a cart.
      assert html =~ "data-lavash-overlay-trigger"
    end

    test "featured cards separate navigation from the add action", %{conn: conn} do
      create_product!()
      {:ok, _view, html} = live(conn, "/storefront")

      # Real button, not a decorative span inside the card link.
      assert html =~ ~s(phx-click="add_to_cart")
      refute html =~ ~r/<a[^>]*>(?:(?!<\/a>)[\s\S])*phx-click="add_to_cart"/
    end

    test "add to cart persists a cart item via the flyover's upsert", %{conn: conn} do
      product = create_product!()
      conn = get(conn, "/storefront")
      user = conn.assigns.current_user

      {:ok, view, _html} = live(conn, "/storefront")

      view
      |> element(~s(button[phx-value-product_id="#{product.id}"]))
      |> render_click()

      # invoke routes via send_update — follow-up render settles it.
      _ = render(view)

      {:ok, cart} =
        Demo.Cart.Cart
        |> Ash.Query.for_read(:for_user, %{user_id: user.id})
        |> Ash.read_one()

      [item] =
        CartItem
        |> Ash.Query.for_read(:for_cart, %{cart_id: cart.id})
        |> Ash.read!()

      assert item.product_id == product.id
      assert item.quantity == 1
    end
  end
end
