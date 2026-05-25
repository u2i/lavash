defmodule DemoWeb.Admin.CategoriesLiveTest do
  use DemoWeb.ConnCase
  import Phoenix.LiveViewTest

  describe "admin categories" do
    test "renders the categories table or empty state", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/categories")
      assert html =~ "Categories"
      assert html =~ "New Category"
    end
  end
end
