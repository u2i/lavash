defmodule DemoWeb.Storefront.ProductLiveTest do
  use DemoWeb.ConnCase
  import Phoenix.LiveViewTest

  describe "storefront product" do
    test "unknown product id redirects to products listing", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/storefront/products"}}} =
               live(conn, "/storefront/products/00000000-0000-0000-0000-000000000000")
    end

    # Regression: URL state used to hydrate only in handle_params, so the
    # mount-time product load always saw a nil product_id — EVERY product
    # page bounced back to the index, and the redirect test above kept
    # passing for the wrong reason.
    test "known product id renders the product page", %{conn: conn} do
      product =
        Demo.Catalog.Product
        |> Ash.Changeset.for_create(:create, %{
          name: "Hydration Blend",
          price: Decimal.new("18.00"),
          description: "A test roast",
          origin: "Testland",
          roast_level: :medium,
          rating: Decimal.new("4.5"),
          tasting_notes: "citrus, regression",
          weight_oz: 12,
          in_stock: true
        })
        |> Ash.create!()

      # First request runs the EnsureUser plug so a user + session exist.
      conn = get(conn, "/storefront/products")

      {:ok, _view, html} = live(conn, "/storefront/products/#{product.id}")
      assert html =~ "Hydration Blend"
    end
  end
end
