defmodule Lavash.ComponentTest do
  use Lavash.ConnCase, async: true

  describe "component mount" do
    test "renders initial state from props", %{conn: conn} do
      {:ok, view, html} = live(conn, "/component-host")
      # The counter component should render with initial count from props (5)
      assert html =~ ~s(id="counter-count">)
      assert has_element?(view, "#counter-count")
    end

    test "computes derived state on mount", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/component-host")
      # doubled = count * 2, where count starts at default 0 from ephemeral state
      # The initial_count prop is 5 but ephemeral state starts at default
      assert has_element?(view, "#counter-doubled")
    end
  end

  describe "component actions" do
    test "increment updates ephemeral state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/component-host")

      # Get initial value
      initial_html = element(view, "#counter-count") |> render()

      # Click increment
      view |> element("#counter-inc") |> render_click()

      # Count should have increased
      updated_html = element(view, "#counter-count") |> render()
      refute initial_html == updated_html
    end

    test "decrement updates ephemeral state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/component-host")

      # First increment to have a non-zero value
      view |> element("#counter-inc") |> render_click()
      view |> element("#counter-inc") |> render_click()

      # Now decrement
      view |> element("#counter-dec") |> render_click()

      # Check that count changed
      assert element(view, "#counter-count") |> render() =~ "1"
    end

    test "reset sets count to zero", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/component-host")

      # Increment a few times
      view |> element("#counter-inc") |> render_click()
      view |> element("#counter-inc") |> render_click()

      # Reset
      view |> element("#counter-reset") |> render_click()

      # Count should be 0
      assert element(view, "#counter-count") |> render() =~ "0"
    end
  end

  describe "derived state from props" do
    test "computes derived from prop value", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/component-host")
      # The derived component gets value from counter_value (5)
      # computed = value * multiplier = 5 * 2 = 10
      assert element(view, "#derived-value") |> render() =~ "5"
      assert element(view, "#derived-computed") |> render() =~ "10"
    end

    test "derived recomputes when parent changes prop", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/component-host")

      # Initial value = 5, computed = 10
      assert element(view, "#derived-value") |> render() =~ "5"
      assert element(view, "#derived-computed") |> render() =~ "10"

      # Click button to set value to 10
      view |> element("#set-10") |> render_click()

      # Now value = 10, computed = 20
      assert element(view, "#derived-value") |> render() =~ "10"
      assert element(view, "#derived-computed") |> render() =~ "20"
    end
  end

  describe "derived chain" do
    test "derived updates when ephemeral state changes", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/component-host")

      # Initial: count = 0, doubled = 0
      assert element(view, "#counter-count") |> render() =~ "0"
      assert element(view, "#counter-doubled") |> render() =~ "0"

      # Increment: count = 1, doubled = 2
      view |> element("#counter-inc") |> render_click()

      assert element(view, "#counter-count") |> render() =~ "1"
      assert element(view, "#counter-doubled") |> render() =~ "2"

      # Increment again: count = 2, doubled = 4
      view |> element("#counter-inc") |> render_click()

      assert element(view, "#counter-count") |> render() =~ "2"
      assert element(view, "#counter-doubled") |> render() =~ "4"
    end
  end
end
