defmodule Lavash.LiveViewTest do
  use Lavash.ConnCase, async: true

  describe "URL state" do
    test "renders initial count from default", %{conn: conn} do
      {:ok, view, html} = live(conn, "/counter")
      assert html =~ ~s(id="count">0</span>)
      assert has_element?(view, "#count", "0")
    end

    test "renders initial count from URL param", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/counter?count=5")
      assert has_element?(view, "#count", "5")
    end

    test "increment updates count", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/counter")

      view |> element("#inc") |> render_click()

      assert has_element?(view, "#count", "1")
    end

    test "decrement updates count", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/counter?count=5")

      view |> element("#dec") |> render_click()

      assert has_element?(view, "#count", "4")
    end

    test "increment updates URL via push_patch", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/counter")

      view |> element("#inc") |> render_click()

      # The URL should be patched
      assert_patch(view, "/counter?count=1")
    end

    test "reset clears count and URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/counter?count=10")

      view |> element("#reset") |> render_click()

      assert has_element?(view, "#count", "0")
      # When count is 0 (default), it should not appear in URL
      assert_patch(view, "/counter")
    end
  end

  describe "derived state" do
    test "computes doubled from count and multiplier", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/counter?count=5")

      # Default multiplier is 2, so doubled = 5 * 2 = 10
      assert has_element?(view, "#doubled", "10")
    end

    test "derived updates when dependency changes", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/counter?count=3")

      # Initial: 3 * 2 = 6
      assert has_element?(view, "#doubled", "6")

      # After increment: 4 * 2 = 8
      view |> element("#inc") |> render_click()
      assert has_element?(view, "#doubled", "8")
    end
  end

  describe "chained derived fields" do
    test "computes initial chain on mount", %{conn: conn} do
      # count=3 → doubled=6 → quadrupled=12 → octupled=24
      {:ok, view, _html} = live(conn, "/chained?count=3")

      assert has_element?(view, "#count", "3")
      assert has_element?(view, "#doubled", "6")
      assert has_element?(view, "#quadrupled", "12")
      assert has_element?(view, "#octupled", "24")
    end

    test "propagates changes through derived chain", %{conn: conn} do
      # Start with count=1 → doubled=2 → quadrupled=4 → octupled=8
      {:ok, view, _html} = live(conn, "/chained")

      assert has_element?(view, "#count", "1")
      assert has_element?(view, "#doubled", "2")
      assert has_element?(view, "#quadrupled", "4")
      assert has_element?(view, "#octupled", "8")

      # Increment: count=2 → doubled=4 → quadrupled=8 → octupled=16
      view |> element("#inc") |> render_click()

      assert has_element?(view, "#count", "2")
      assert has_element?(view, "#doubled", "4")
      assert has_element?(view, "#quadrupled", "8")
      assert has_element?(view, "#octupled", "16")
    end

    test "handles multiple increments through chain", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chained?count=1")

      # Increment twice
      view |> element("#inc") |> render_click()
      view |> element("#inc") |> render_click()

      # count=3 → doubled=6 → quadrupled=12 → octupled=24
      assert has_element?(view, "#count", "3")
      assert has_element?(view, "#doubled", "6")
      assert has_element?(view, "#quadrupled", "12")
      assert has_element?(view, "#octupled", "24")
    end
  end

  describe "chained derived fields with ephemeral state" do
    # This tests recompute_dirty, not recompute_all, since ephemeral
    # state changes don't trigger handle_params

    test "computes initial chain on mount", %{conn: conn} do
      # base=1 → doubled=2 → quadrupled=4 → octupled=8
      {:ok, view, _html} = live(conn, "/chained-ephemeral")

      assert has_element?(view, "#base", "1")
      assert has_element?(view, "#doubled", "2")
      assert has_element?(view, "#quadrupled", "4")
      assert has_element?(view, "#octupled", "8")
    end

    test "propagates ephemeral state change through derived chain", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chained-ephemeral")

      # Increment: base=2 → doubled=4 → quadrupled=8 → octupled=16
      view |> element("#inc") |> render_click()

      assert has_element?(view, "#base", "2")
      assert has_element?(view, "#doubled", "4")
      assert has_element?(view, "#quadrupled", "8")
      assert has_element?(view, "#octupled", "16")
    end
  end

  describe "async derived chain" do
    test "shows loading state initially, then computes chain", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/async-chain")

      # Initially both should be loading (doubled is async, quadrupled depends on it)
      assert has_element?(view, "#doubled", "loading")
      assert has_element?(view, "#quadrupled", "loading")

      # Wait for async to complete
      Process.sleep(100)

      # After async completes, both should have values
      # count=1 → doubled=2 → quadrupled=4
      # Use text_content matching which handles whitespace
      assert element(view, "#doubled") |> render() =~ "2"
      assert element(view, "#quadrupled") |> render() =~ "4"
    end

    test "propagates through chain when async completes after action", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/async-chain")

      # Wait for initial async to complete
      Process.sleep(100)

      # Increment count
      view |> element("#inc") |> render_click()

      # Should show loading again
      assert has_element?(view, "#doubled", "loading")
      assert has_element?(view, "#quadrupled", "loading")

      # Wait for async to complete
      Process.sleep(100)

      # count=2 → doubled=4 → quadrupled=8
      assert element(view, "#doubled") |> render() =~ "4"
      assert element(view, "#quadrupled") |> render() =~ "8"
    end
  end

  describe "typed URL fields" do
    test "parses integer from URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/typed?page=42")
      assert has_element?(view, "#page", "42")
    end

    test "parses boolean from URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/typed?active=true")
      assert has_element?(view, "#active", "true")
    end

    test "parses string from URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/typed?query=hello")
      assert has_element?(view, "#query", "hello")
    end

    test "parses array from URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/typed?tags=a,b,c")
      assert has_element?(view, "#tags", "a,b,c")
    end

    test "uses defaults when params missing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/typed")
      assert has_element?(view, "#page", "1")
      assert has_element?(view, "#active", "false")
      assert has_element?(view, "#query", "")
      assert has_element?(view, "#tags", "")
    end

    test "toggle updates boolean and URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/typed")

      view |> element("#toggle") |> render_click()

      assert has_element?(view, "#active", "true")
      assert_patch(view, "/typed?active=true")
    end

    test "next page updates integer and URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/typed?page=5")

      view |> element("#next-page") |> render_click()

      assert has_element?(view, "#page", "6")
      assert_patch(view, "/typed?page=6")
    end
  end
end
