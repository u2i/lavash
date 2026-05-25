defmodule DemoWeb.ComponentsDemoLiveTest do
  use DemoWeb.ConnCase
  import Phoenix.LiveViewTest

  describe "components demo" do
    test "renders the components demo page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/demos/components")
      assert html =~ "Lavash Components Demo"
      assert html =~ "ProductCard with socket state"
    end
  end
end
