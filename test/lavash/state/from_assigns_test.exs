defmodule Lavash.State.FromAssignsTest do
  @moduledoc """
  `from: :assigns` lifts a value an `on_mount` hook put on
  `socket.assigns` into lavash state, so it's visible to `rx()` and
  participates in the reactive graph.

  Mirrors the real-world use case: `AshAuthentication.LiveView`'s
  `:live_user_required` on_mount assigns `:current_user`, and an LV
  wants to read that in `rx(@user.email)` without writing a custom
  mount/3 to bridge.
  """
  use Lavash.ConnCase, async: false

  test "from: :assigns hydrates from socket.assigns at mount", %{conn: conn} do
    # The fixture's on_mount plants:
    #   %{id: "u-123", email: "alice@example.com", name: "Alice"}
    {:ok, view, _html} = live(conn, "/magic/assigns")

    assert has_element?(view, "#user-email", "alice@example.com")
    assert has_element?(view, "#user-name", "Alice")
  end

  test "rx() can compute against an assigns-sourced field", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/magic/assigns")

    # calculate :greeting, rx("Hello, " <> @user.name)
    assert has_element?(view, "#greeting", "Hello, Alice")
  end

  test "missing assign falls back to default", %{conn: conn} do
    # The fixture declares `state :missing, :string, from: :assigns,
    # default: "guest"`. No on_mount sets :missing, so default wins.
    {:ok, view, _html} = live(conn, "/magic/assigns")

    assert has_element?(view, "#missing", "guest")
  end
end
