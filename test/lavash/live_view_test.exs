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
