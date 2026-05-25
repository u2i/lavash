defmodule DemoWeb.Admin.ProductsLiveTest do
  use DemoWeb.ConnCase
  import Phoenix.LiveViewTest

  describe "admin products" do
    test "renders heading and add button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/products")
      assert html =~ "Products"
      assert html =~ "Add Product"
    end

    test "clear_filters resets the URL-state filters", %{conn: conn} do
      {:ok, view, html} = live(conn, "/admin/products?search=foo")
      # The search input reflects the URL state
      assert html =~ ~s|value="foo"|

      html = view |> element("button.btn-ghost", ~r/^\s*Clear\s*$/) |> render_click()
      # Search input has been cleared
      assert html =~ ~s|value=""|
      refute html =~ ~s|value="foo"|
    end
  end
end
