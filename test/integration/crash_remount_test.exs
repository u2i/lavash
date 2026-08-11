defmodule Lavash.Integration.CrashRemountTest do
  @moduledoc """
  What survives the LiveView process DYING mid-session (issue #76) —
  the failure mode a page reload can't proxy (reload wipes the JS
  heap; a crash-rejoin keeps it, so the layer-2 reconnect cache and
  the URL both get their say on remount).

  The `_lavash_dev_crash` event (config :lavash, :dev_crash_event —
  enabled in test_helper) raises inside the LiveView so the process
  exits; LiveView's client auto-rejoins and the page remounts.

  ## Why async: false

  Crashing LiveViews writes error noise into the shared logger and the
  rejoin timing is load-sensitive.
  """
  use Lavash.IntegrationCase, async: false

  @crash_js ~s|liveSocket.execJS(document.querySelector('[data-phx-main]'), '[["push",{"event":"_lavash_dev_crash"}]]')|

  defp crash(session) do
    execute_script(session, @crash_js, fn _ -> send(self(), :crashed) end)

    receive do
      :crashed -> session
    after
      2_000 -> session
    end
  end

  test "socket-backed state survives the crash-remount via the reconnect cache",
       %{session: session} do
    session =
      session
      |> visit("/magic/socket-counter")
      |> click(css("#bump"))
      |> click(css("#bump"))
      |> assert_has(css("#count", text: "2"))

    session = crash(session)

    # The client rejoins with _lavash_state in connect_params; the
    # remounted server seeds count=2 instead of the default 0. A
    # RELOAD of this page would show 0 — the JS heap (and with it the
    # sync cache) is what carries the value across the crash.
    assert_has(session, css("#count", text: "2", wait: 4_000))
  end

  test "ephemeral state resets on crash-remount (the documented boundary)",
       %{session: session} do
    session =
      session
      |> visit("/magic/dom-directives")
      |> click(css("#bump"))
      |> assert_has(css("p", text: "Count: 1"))

    session = crash(session)

    assert_has(session, css("p", text: "Count: 0", wait: 4_000))
  end

  test "a URL-open overlay is open again after the crash-remount", %{session: session} do
    session =
      session
      |> visit("/magic/modal-ssr-host?modal_item=42")
      |> assert_has(css("#modal-content h2", text: "Editing item 42"))

    session = crash(session)

    # Remount re-reads the URL; the SSR-open seed path (issue #30)
    # brings the modal back in the visible phase.
    session = assert_has(session, css("#modal-content h2", text: "Editing item 42", wait: 4_000))
    assert_has(session, css(~s([data-modal-phase="visible"])))
  end
end
