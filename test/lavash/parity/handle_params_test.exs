defmodule Lavash.Parity.HandleParamsTest do
  @moduledoc """
  Parity suite: `handle_params/3` features.

  Note on idiom: in vanilla LV, URL-bound state requires you to
  call `push_patch` in every event handler that wants to update
  the URL. In lavash, `state :foo, from: :url` declares the binding
  once and any mutation to `:foo` auto-syncs the URL. Same
  observable behaviour, two routes to get there.
  """
  use Lavash.ConnCase, async: true

  @paths [
    {"vanilla", "/parity/vanilla/handle_params"},
    {"lavash", "/parity/lavash/handle_params"}
  ]

  for {label, path} <- @paths do
    @path path

    describe "URL params hydrate on mount (#{label})" do
      test "defaults when no query string", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path)
        assert has_element?(view, "#tab", "overview")
        assert has_element?(view, "#page", "1")
      end

      test "query params populate state", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path <> "?tab=billing&page=3")
        assert has_element?(view, "#tab", "billing")
        assert has_element?(view, "#page", "3")
      end

      test "calculated title combines two url-derived fields", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path <> "?tab=billing&page=3")
        assert has_element?(view, "#title", "Tab: billing (page 3)")
      end
    end

    describe "handle_params re-fires on URL change (#{label})" do
      test "clicking goto-billing changes tab in state", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path)
        assert has_element?(view, "#tab", "overview")

        view |> element("#goto-billing") |> render_click()
        assert has_element?(view, "#tab", "billing")
      end

      test "next-page bumps page", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path <> "?page=2")
        view |> element("#next-page") |> render_click()
        assert has_element?(view, "#page", "3")
      end

      test "calculated title updates when tab changes", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path)

        view |> element("#goto-billing") |> render_click()
        assert has_element?(view, "#title", ~r/billing/)
      end
    end

    # URL sync mechanism diverges between vanilla and lavash:
    #
    # - Vanilla pushes patches server-side (the LiveViewTest can see
    #   `assert_patch`).
    # - Lavash syncs URLs client-side via the JS hook
    #   (`history.replaceState` in `LavashOptimistic`). No server
    #   patch fires, so `assert_patch` reports "got none."
    #
    # The user-visible behaviour is the same (URL reflects current
    # state, refresh reproduces page), but the mechanism differs.
    # The tests above cover the observable result via state assertions.
  end
end
