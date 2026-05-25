defmodule DemoWeb.ProductsLiveTest do
  use DemoWeb.ConnCase
  import Phoenix.LiveViewTest

  describe "products (URL state)" do
    test "renders heading", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/demos/products")
      assert html =~ "Product Catalog (URL State)"
    end

    test "search filter from URL is reflected in input", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/demos/products?search=widget")
      assert html =~ ~s|value="widget"|
    end
  end
end
