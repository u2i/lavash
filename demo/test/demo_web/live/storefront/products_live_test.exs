defmodule DemoWeb.Storefront.ProductsLiveTest do
  use DemoWeb.ConnCase
  import Phoenix.LiveViewTest

  describe "storefront products" do
    test "mounts and renders the page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/storefront/products")
      assert html =~ "lavash-optimistic-root"
    end
  end
end
