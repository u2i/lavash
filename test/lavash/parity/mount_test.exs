defmodule Lavash.Parity.MountTest do
  @moduledoc """
  Parity suite: `mount/3` features.

  Same `for {label, prefix}` pattern as the handle_event suite — each
  test runs against both `/parity/vanilla/mount` and
  `/parity/lavash/mount`. The two sides must produce the same
  observable behaviour.

  Documented gaps (DSL can't yet declare these natively, so the
  lavash fixture uses a custom `mount/3` to match vanilla):

    * `from: :session` for state hydration
    * `connected?(socket)` branching at mount
    * `temporary_assigns` declaration on the mount return
  """
  use Lavash.ConnCase, async: true

  @paths [
    {"vanilla", "/parity/vanilla/mount"},
    {"lavash", "/parity/lavash/mount"}
  ]

  # Plug.Test puts the session map into the conn so LiveView's mount
  # sees it. Both vanilla and lavash sides read the same key.
  defp with_session(conn, session_map) do
    conn
    |> Plug.Test.init_test_session(session_map)
  end

  for {label, path} <- @paths do
    @path path

    describe "default-value hydration (#{label})" do
      test "literal default for :count when no URL param", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path)
        assert has_element?(view, "#count", "0")
      end

      test "URL param hydrates :count", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path <> "?count=42")
        assert has_element?(view, "#count", "42")
      end

      test "literal default for :handle when session is empty", %{conn: conn} do
        {:ok, view, _html} = conn |> with_session(%{}) |> live(@path)
        assert has_element?(view, "#handle", "guest")
      end
    end

    describe "session hydration (#{label})" do
      test ":handle pulled from session map", %{conn: conn} do
        {:ok, view, _html} =
          conn
          |> with_session(%{"handle" => "alice"})
          |> live(@path)

        assert has_element?(view, "#handle", "alice")
      end

      test "calculated greeting reflects session-hydrated handle", %{conn: conn} do
        {:ok, view, _html} =
          conn
          |> with_session(%{"handle" => "bob"})
          |> live(@path)

        assert has_element?(view, "#greeting", "Hello, bob")
      end
    end

    describe "connected?/1 branching (#{label})" do
      test "connected? is true after the live socket connects", %{conn: conn} do
        # `live/2` performs both the static render AND the connect.
        # After mount-with-connect, @connected_at is set.
        {:ok, view, _html} = live(conn, @path)
        assert has_element?(view, "#connected", "true")
      end

      test "connected? is false on the initial static render", %{conn: conn} do
        # `get/2` only does the static render (no socket connection).
        # @connected_at stays nil.
        conn = get(conn, @path)
        assert html_response(conn, 200) =~ ~s|id="connected">false|
      end
    end

    describe "temporary_assigns (#{label})" do
      test ":notifications doesn't accumulate across clicks", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path)

        # temporary_assigns means the assign is reset to its
        # declared empty value AFTER each render. So each `notify`
        # click sees `@notifications == []` at the start of its
        # handler and prepends one item, giving length 1.
        # Without temporary_assigns the list would grow to 2, 3, ...
        view |> element("#notify") |> render_click()
        assert has_element?(view, "#notif-count", "1")

        view |> element("#notify") |> render_click()
        assert has_element?(view, "#notif-count", "1")

        view |> element("#notify") |> render_click()
        assert has_element?(view, "#notif-count", "1")
      end
    end
  end
end
