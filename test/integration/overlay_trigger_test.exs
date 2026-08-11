defmodule Lavash.Integration.OverlayTriggerTest do
  @moduledoc """
  `template_trigger` end-to-end: clicking the trigger opens the
  overlay optimistically (client-side, inside the latency window),
  and the client a11y stack keeps the trigger's aria-expanded
  current through optimistic open/close.

  ## Why async: false

  Latency simulator + global focus/overlay state.
  """
  use Lavash.IntegrationCase, async: false

  alias Wallabidi.LiveView, as: WLV

  @latency_ms 1_000
  @trigger ~s([data-lavash-overlay-trigger="trig-fly-flyover"])

  test "trigger click opens the flyover optimistically", %{session: session} do
    session =
      session
      |> visit("/magic/trigger-flyover")
      |> WLV.set_latency(@latency_ms)

    session = assert_has(session, css(~s(#{@trigger}[aria-expanded="false"])))

    try do
      session = click(session, css(@trigger), await: :defer)

      # Deep inside the lag window: phase already left idle client-side
      # and the trigger reports expanded.
      session =
        assert_has(
          session,
          css(
            ~s(#lavash-trig-fly[data-flyover-phase="entering"], #lavash-trig-fly[data-flyover-phase="visible"])
          )
        )

      session = assert_has(session, css(~s(#{@trigger}[aria-expanded="true"])))

      # Settles open after the round trip.
      session = WLV.await_patch(session)
      session = assert_has(session, css(~s(#lavash-trig-fly[data-flyover-phase="visible"])))

      # Escape closes (a11y stack) and the trigger reports collapsed again.
      session = send_keys(session, [:escape])
      session = assert_has(session, css(~s(#lavash-trig-fly[data-flyover-phase="idle"])))
      assert_has(session, css(~s(#{@trigger}[aria-expanded="false"])))
    after
      _ = WLV.clear_latency(session)
    end
  end
end
