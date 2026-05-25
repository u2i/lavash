defmodule DemoWeb.Storefront.ProductLiveTest do
  use DemoWeb.ConnCase
  import Phoenix.LiveViewTest

  describe "storefront product" do
    test "unknown product id redirects to products listing", %{conn: conn} do
      # No products are seeded in the test DB; the LiveView's on_mount
      # push_navigates to /storefront/products on a missing product.
      assert {:error, {:live_redirect, %{to: "/storefront/products"}}} =
               live(conn, "/storefront/products/00000000-0000-0000-0000-000000000000")
    end
  end
end
