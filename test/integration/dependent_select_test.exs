defmodule Lavash.Integration.DependentSelectTest do
  @moduledoc """
  Dependent selects: one select's value determines another select's
  option list, in both flavors (see the DependentSelectLive fixture):

  - optimistic — the option list is a transpiled defrx calc rendered by
    a subtree derive; it must swap client-side while the server reply
    is still in flight.
  - non-optimistic — the same calc marked `optimistic: false`; the swap
    must NOT appear before the server render lands, and must appear
    with it.

  No custom JS: `visit/2` (wallabidi >= 0.4.3) waits for the LiveView
  to connect, the country change is dispatched with `await: :defer`,
  and the latency simulator makes "before the server replied" a wide
  window — the in-window assertions complete in ~10ms against a
  1000ms window (measured), so anything they observe is
  client-rendered.

  Two wallabidi subtleties this test depends on:

  - `refute_has/2` RETRIES until the element appears (then fails) or
    the wait window closes — it asserts "never appears within the
    window", which would race the legitimate server patch here. The
    instant "absent right now" check is `all/2` (its `minimum: 0`
    succeeds immediately), asserted `== []`.
  - Options inside a closed `<select>` don't count as visible; query
    them with `visible: :any`.

  ## Why async: false

  Uses the LiveView latency simulator (sessionStorage on the shared
  browser session); concurrent tests would cross-pollute it, and the
  in-window margin assumes no competing CPU load.
  """
  use Lavash.IntegrationCase, async: false

  alias Wallabidi.LiveView, as: WLV

  @latency_ms 1_000

  defp region_option(select_id, text) do
    css("##{select_id} option", text: text, visible: :any)
  end

  test "optimistic swaps before the server reply; non-optimistic waits for it", %{
    session: session
  } do
    session =
      session
      |> visit("/magic/dependent-select")
      |> WLV.set_latency(@latency_ms)

    # Baseline: both region selects show the US list.
    session
    |> assert_has(region_option("fast-region", "California"))
    |> assert_has(region_option("slow-region", "California"))

    try do
      # Change the country without waiting for the server ack.
      session = click(session, css("#country option[value='CA']", visible: :any), await: :defer)

      # Optimistic: already swapped, deep inside the lag window — no
      # server reply exists yet.
      assert_has(session, region_option("fast-region", "Ontario"))

      # Non-optimistic: nothing Canadian yet (instant check — see
      # moduledoc for why this must not be refute_has).
      assert all(session, region_option("slow-region", "Ontario")) == []
      assert_has(session, region_option("slow-region", "California"))

      # After the round-trip both agree on the Canadian list.
      session = WLV.await_patch(session)
      assert_has(session, region_option("slow-region", "Ontario"))
      assert_has(session, region_option("fast-region", "Ontario"))
    after
      _ = WLV.clear_latency(session)
    end
  end
end
