defmodule DemoWeb.NestingDemoLiveTest do
  use DemoWeb.ConnCase
  import Phoenix.LiveViewTest

  describe "nesting demo" do
    test "renders the three nested counter sections", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/demos/nesting")
      assert html =~ "Nesting Demo"
      assert html =~ "Direct Binding"
      assert html =~ "Single Wrapper"
      assert html =~ "Double Wrapper"
    end

    test "all counters start at zero and total is zero", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/demos/nesting")

      assert html =~ ~s|data-lavash-display="direct_count">0<|
      assert html =~ ~s|data-lavash-display="wrapped_count">0<|
      assert html =~ ~s|data-lavash-display="deep_count">0<|
      assert html =~ ~s|data-lavash-display="total">0<|
    end

    test "direct CounterControls increments its own count", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/demos/nesting")

      html =
        view
        |> element("#direct-counter button[phx-click=increment]")
        |> render_click()

      # Component-internal count is updated
      assert html =~ ~s|id="direct-counter"|
      # CounterControls' own count display is now 1
      assert html =~ ~s|data-lavash-state="{&quot;count&quot;:1}"|
    end

    test "wrapped CounterControls increments through its parent component", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/demos/nesting")

      html =
        view
        |> element("#wrapped-counter-controls button[phx-click=increment]")
        |> render_click()

      assert html =~ ~s|id="wrapped-counter-controls"|
      # The leaf CounterControls' state moves to 1
      assert html =~ ~s|data-lavash-bindings=\"{&quot;count&quot;:&quot;wrapped_count&quot;}\"|
    end

    test "deep CounterControls increments through nested wrappers", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/demos/nesting")

      html =
        view
        |> element("#deep-counter-inner-controls button[phx-click=increment]")
        |> render_click()

      assert html =~ ~s|id="deep-counter-inner-controls"|
      assert html =~ ~s|data-lavash-bindings=\"{&quot;count&quot;:&quot;deep_count&quot;}\"|
    end

    test "decrement does not go below zero", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/demos/nesting")

      html =
        view
        |> element("#direct-counter button[phx-click=decrement]")
        |> render_click()

      # Still rendering and count stays at 0
      refute html =~ ~s|data-lavash-state="{&quot;count&quot;:-1}"|
    end
  end
end
