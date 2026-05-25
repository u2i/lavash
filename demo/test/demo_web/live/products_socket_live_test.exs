defmodule DemoWeb.ProductsSocketLiveTest do
  use DemoWeb.ConnCase
  import Phoenix.LiveViewTest

  describe "products (socket state)" do
    test "renders heading and filters sidebar", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/demos/products-socket")
      assert html =~ "Product Catalog (Socket State)"
      assert html =~ "Filters"
      assert html =~ "Search"
    end
  end
end
