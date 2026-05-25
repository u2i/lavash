defmodule Lavash.Parity.HandleEventTest do
  @moduledoc """
  Parity suite: `handle_event` features.

  Every test runs against BOTH `/parity/vanilla/handle_event` (a
  hand-written `Phoenix.LiveView`) and `/parity/lavash/handle_event`
  (the same behaviour expressed through the lavash DSL). If they
  diverge, the lavash side has drifted from vanilla semantics.

  Tests tagged with `@tag :parity_gap` document a known gap where
  lavash cannot yet express the vanilla behaviour. They're excluded
  by default — running with `--include parity_gap` shows the work
  still to do.
  """
  use Lavash.ConnCase, async: true

  @paths [
    {"vanilla", "/parity/vanilla/handle_event"},
    {"lavash", "/parity/lavash/handle_event"}
  ]

  for {label, path} <- @paths do
    @path path

    describe "phx-click → action (#{label})" do
      test "basic increment", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path)
        view |> element("#inc") |> render_click()
        assert has_element?(view, "#count", "1")
      end

      test "phx-value-* params flow through", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path)
        view |> element("#bump-by") |> render_click()
        assert has_element?(view, "#count", "5")
      end

      test "string-typed phx-value-* params are received as strings", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path)
        view |> element("#track") |> render_click()
        assert has_element?(view, "#last-event", "howdy")
      end

      test "action guard with action-level `when:` blocks when false", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path)
        # Default: is_admin? = true → guarded_inc runs
        view |> element("#guarded-inc") |> render_click()
        assert has_element?(view, "#count", "1")

        # Toggle admin off → guarded_inc is a no-op
        view |> element("#toggle-admin") |> render_click()
        assert has_element?(view, "#is-admin", "false")

        view |> element("#guarded-inc") |> render_click()
        assert has_element?(view, "#count", "1")
      end

      test "navigate to another live route", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path)

        assert {:error, {:live_redirect, %{to: to}}} =
                 view |> element("#navigate-demo") |> render_click()

        assert to =~ ~r{/parity/(vanilla|lavash)/handle_event_landing}
      end
    end

    describe "navigation & client events (#{label})" do
      test "push_event sends a client event (doesn't crash)", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path)
        view |> element("#push-demo") |> render_click()
        # Payload-shape assertions live in the Wallabidi integration
        # suite — LiveViewTest doesn't surface push_event payloads.
      end

      test "push_patch updates URL without remount", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path)
        view |> element("#patch-demo") |> render_click()
        assert_patched(view, @path <> "?via=patch")
      end

      test "redirect (external/non-live) full-page redirects", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path)

        assert {:error, {:redirect, %{to: to}}} =
                 view |> element("#redirect-demo") |> render_click()

        assert to =~ "handle_event_landing"
      end
    end
  end
end
