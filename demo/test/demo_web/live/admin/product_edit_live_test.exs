defmodule DemoWeb.Admin.ProductEditLiveTest do
  use DemoWeb.ConnCase
  import Phoenix.LiveViewTest

  describe "admin product edit" do
    test "new product route mounts and shows back link", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/products/new")
      # In the initial (loading) render the heading falls back to "Edit Product",
      # but the back-link and loading skeleton always render.
      assert html =~ ~s|href="/admin/products"|
      assert html =~ "animate-pulse"
    end
  end
end
