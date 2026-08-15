defmodule DemoWeb.CounterLiveTest do
  use DemoWeb.ConnCase
  import Phoenix.LiveViewTest

  describe "counter" do
    test "renders initial state", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dsl/counter")
      assert html =~ "Lavash Counter Demo"
      assert html =~ ~s|data-lavash-display="count">0<|
    end

    test "increment / decrement update the count", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dsl/counter")

      assert view |> element("button", "+") |> render_click() =~ ">1<"
      assert view |> element("button", "+") |> render_click() =~ ">2<"
      assert view |> element("button", "-") |> render_click() =~ ">1<"
    end

    test "set_count with phx-value-amount sets the count to 100", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dsl/counter")

      assert view |> element("button", "Set to 100") |> render_click() =~ ">100<"
    end

    test "reset returns count and multiplier to defaults", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dsl/counter?count=42")

      html = view |> element("button", "Reset") |> render_click()
      assert html =~ ">0<"
    end

    test "computed doubled reflects count * multiplier", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dsl/counter?count=5")
      # default multiplier is 2, so doubled = 5 * 2 = 10
      html = render(view)
      assert html =~ ~s|data-lavash-display="count">5<|
      assert html =~ ~s|data-lavash-display="doubled">10<|
    end
  end
end
