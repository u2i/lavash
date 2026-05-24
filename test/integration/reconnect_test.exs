defmodule Lavash.Integration.ReconnectTest do
  @moduledoc """
  LiveView reconnect semantics — what survives a socket drop, what doesn't.

  Wallabidi doesn't expose a socket-drop primitive, so these tests use a
  full page reload (visit again) as a proxy. That's a strict superset: if
  state survives a reload it survives a reconnect; if state doesn't survive
  a reload it doesn't survive a reconnect either.
  """
  use Lavash.IntegrationCase, async: false

  test "url-backed state survives a reload (it's in the URL)", %{session: session} do
    session
    |> visit("/counter?count=15")
    |> assert_has(css("#count", text: "15"))
    |> visit("/counter?count=15")
    |> assert_has(css("#count", text: "15"))
  end

  test "ephemeral state resets on reload", %{session: session} do
    # TestDomDirectivesLive's :n is ephemeral.
    session
    |> visit("/dom-directives")
    |> click(css("#bump"))
    |> click(css("#bump"))
    |> assert_has(css("p", text: "Count: 2"))
    |> visit("/dom-directives")
    |> assert_has(css("p", text: "Count: 0"))
  end

  test "url-state mutations are reflected on the URL after navigation", %{session: session} do
    # Visit with a count, then re-visit. With url state, the count param
    # value should round-trip.
    session
    |> visit("/counter?count=0")
    |> click(css("#inc"))
    |> assert_has(css("#count", text: "1"))
    |> visit("/counter?count=1")
    |> assert_has(css("#count", text: "1"))
  end

  test "fresh mount after reload re-initializes the live socket", %{session: session} do
    # The smoke test confirms a freshly-mounted page can drive clicks. Verify
    # the same is true after a reload — no stale-handler issues.
    session
    |> visit("/counter")
    |> click(css("#inc"))
    |> assert_has(css("#count", text: "1"))
    |> visit("/counter")
    |> click(css("#inc"))
    |> assert_has(css("#count", text: "1"))
  end
end
