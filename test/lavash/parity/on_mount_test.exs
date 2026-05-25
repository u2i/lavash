defmodule Lavash.Parity.OnMountTest do
  @moduledoc """
  Parity suite: `on_mount` hooks.

  Both sides install the same `Lavash.Parity.OnMountHook` module
  via `on_mount {Mod, :tag}` declarations. The lavash side adds
  no new DSL — `on_mount` is part of `Phoenix.LiveView`'s own
  surface and works unchanged inside a `use Lavash.LiveView`
  module.

  Verified: hook chain order, halt-and-redirect, assigns set by
  the hook are visible in the LV's render.
  """
  use Lavash.ConnCase, async: true

  @paths [
    {"vanilla", "/parity/vanilla/on_mount"},
    {"lavash", "/parity/lavash/on_mount"}
  ]

  defp with_session(conn, session_map) do
    Plug.Test.init_test_session(conn, session_map)
  end

  for {label, path} <- @paths do
    @path path

    describe "on_mount with valid session (#{label})" do
      test "current_user_id surfaces from session via the require_user hook", %{conn: conn} do
        {:ok, view, _html} =
          conn
          |> with_session(%{"user_id" => "alice"})
          |> live(@path)

        assert has_element?(view, "#current-user-id", "alice")
      end

      test "derived email is computed by the hook", %{conn: conn} do
        {:ok, view, _html} =
          conn
          |> with_session(%{"user_id" => "bob"})
          |> live(@path)

        assert has_element?(view, "#current-user-email", "bob@example.com")
      end

      test "second hook in the chain runs", %{conn: conn} do
        {:ok, view, _html} =
          conn
          |> with_session(%{"user_id" => "carol"})
          |> live(@path)

        assert has_element?(view, "#audited", "true")
      end
    end

    describe "on_mount halt-and-redirect (#{label})" do
      test "missing session redirects to login", %{conn: conn} do
        assert {:error, {:redirect, %{to: "/parity/login"}}} =
                 conn
                 |> with_session(%{})
                 |> live(@path)
      end
    end
  end
end
