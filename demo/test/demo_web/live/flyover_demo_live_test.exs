defmodule DemoWeb.FlyoverDemoLiveTest do
  use DemoWeb.ConnCase
  import Phoenix.LiveViewTest

  describe "flyover demo" do
    test "renders both flyover triggers", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dsl/flyover")
      assert html =~ "Flyover (Slideover) Demo"
      assert html =~ "Open Navigation"
      assert html =~ "Open Details"
      assert html =~ "nav-flyover"
      assert html =~ "details-flyover"
    end

    test "opening the nav flyover updates nav_open", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dsl/flyover")
      html = view |> element("button", "Open Navigation") |> render_click()
      assert html =~ "nav_open"
    end

    test "opening the details flyover updates details_open and renders its content", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dsl/flyover")
      html = view |> element("button", "Open Details") |> render_click()
      assert html =~ "details_open"
      assert html =~ "Product Details"
    end
  end
end
