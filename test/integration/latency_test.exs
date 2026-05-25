defmodule Lavash.Integration.LatencyTest do
  @moduledoc """
  Latency-aware tests for the LavashOptimistic JS hook.

  Each action that touches `optimistic: true` state runs through two
  phases:

    1. **Optimistic phase** — `LavashOptimistic` patches the DOM
       client-side immediately on the user event. No server round-trip
       has occurred yet.
    2. **Reconciliation phase** — the server reply lands; the hook
       merges it with any still-pending optimistic state via
       `mergeServerState` and the SyncedVar phase machine.

  Under real network conditions phase 1 is invisible (round-trips are
  fast). Under the LiveView latency simulator, phase 1 is reliably
  observable, and bugs in the hook's pending-path / version-bump /
  reconciliation logic become catchable.

  These tests are the safety net for the
  `LavashOptimistic`-into-modules refactor (#67). They run on the
  remote browser driver — `await: :defer` and latency simulation are
  no-ops on the in-process LV driver.
  """
  use Lavash.IntegrationCase, async: false

  alias Wallabidi.LiveView, as: WLV

  @latency_ms 400

  describe "optimistic scalar" do
    test "client patch lands before server reply, then reconciles", %{session: session} do
      session
      |> visit("/magic/dom-directives")
      |> WLV.with_latency(@latency_ms, fn s ->
        s
        |> click(css("#bump"), await: :defer)
        # Optimistic phase: client-side incremented to 1 immediately.
        |> assert_has(css("p", text: "Count: 1"))
        |> WLV.await_patch()
        # Reconciliation phase: server reply lands, value stays at 1.
        |> assert_has(css("p", text: "Count: 1"))
      end)
    end
  end

  describe "optimistic boolean" do
    test "class toggle applies before server reply, then reconciles", %{session: session} do
      session
      |> visit("/magic/dom-directives")
      |> WLV.with_latency(@latency_ms, fn s ->
        s
        |> click(css("#toggle-flag"), await: :defer)
        |> assert_has(css("#toggle-target.on-class"))
        |> WLV.await_patch()
        |> assert_has(css("#toggle-target.on-class"))
      end)
    end
  end

  describe "optimistic array member toggle" do
    test "chip membership applies optimistically, survives reconcile", %{session: session} do
      session
      |> visit("/magic/dom-directives")
      |> WLV.with_latency(@latency_ms, fn s ->
        s
        |> click(css("#toggle-three"), await: :defer)
        |> assert_has(css("#chip-three.selected"))
        |> WLV.await_patch()
        |> assert_has(css("#chip-three.selected"))
      end)
    end
  end

  describe "version reconciliation under rapid clicks" do
    test "two clicks in flight resolve to the correct final count", %{session: session} do
      # Both clicks land before either server reply. The second optimistic
      # patch bumps the client to 2; both server replies arrive in order
      # and confirm the chain. Final state must be 2 — a regression in
      # version tracking would either show 1 (second reply lost) or
      # rewind temporarily during reconciliation.
      session
      |> visit("/magic/dom-directives")
      |> WLV.with_latency(@latency_ms, fn s ->
        s
        |> click(css("#bump"), await: :defer)
        |> assert_has(css("p", text: "Count: 1"))
        |> click(css("#bump"), await: :defer)
        |> assert_has(css("p", text: "Count: 2"))
        |> WLV.await_patch()
        |> assert_has(css("p", text: "Count: 2"))
      end)
    end
  end
end
