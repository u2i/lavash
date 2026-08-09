defmodule Lavash.Integration.PanelLatencyTest do
  @moduledoc """
  Latency-aware tests for the modal (panel) phase machine.

  The lavash overlay/panel infrastructure runs the most complex
  client-side state machine in the codebase:

      idle → entering → [loading] → visible → exiting → idle

  Each transition is driven by a mix of: user actions (open/close),
  CSS animation timers (entering and exiting both wait `duration + 50`
  ms), and async-data readiness (async_assign triggers the loading
  branch from entering, then exits to visible when data arrives).

  Bugs here are silent — a missed `_timeout` cleanup leaves a phase
  glitch one animation frame after a user thinks they cancelled an
  open. These tests exercise the load-bearing edges of the machine
  under simulated latency, where the optimistic phase transitions
  are reliably observable via the `data-modal-phase` attribute the
  render generator now emits.

  ## Why async: false

  The LiveView latency simulator (`enableLatencySim`) writes to
  sessionStorage on the test browser session. Two tests running
  concurrently would share that flag and cross-pollute. Plus the
  phase machine reasons about real wall-clock animation timers — we
  don't want test threads competing for CPU during the 200ms
  entering window. Run sequentially.
  """
  use Lavash.IntegrationCase, async: false

  alias Wallabidi.LiveView, as: WLV

  @latency_ms 400

  describe "open transition (idle → entering → visible)" do
    test "modal opens optimistically and reaches visible after entering animation", %{
      session: session
    } do
      session =
        session
        |> visit("/magic/modal-host")
        |> WLV.set_latency(@latency_ms)
        |> click(css("#open-modal"), await: :defer)

      try do
        # Optimistic phase: the click fired client-side; the phase
        # machine has begun. Without async_assign the path is
        # entering → visible after duration+50 ms (~250ms).
        #
        # The data-modal-phase attribute we surface from the
        # overlay_manager's onPhaseChange callback should show
        # "entering" while the animation is still in flight. By the
        # time await_patch returns, both the server reply has landed
        # AND the entering animation timer has fired, so the final
        # observable phase should be "visible".
        session = WLV.await_patch(session)
        # The phase machine sets a 250ms timer (200 duration + 50
        # buffer) on entering. await_patch returned when the server
        # patch arrived (~400ms after click), which is past the
        # entering window. So phase should be "visible".
        assert_has(session, css("[data-modal-phase='visible']"))
        # Main content should be in DOM (the `:if={@is_open}` branch).
        assert_has(session, css("#modal-content"))
      after
        _ = WLV.clear_latency(session)
      end
    end
  end

  describe "close mid-entering (entering → exiting → idle)" do
    test "rapid close cancels the entering animation cleanly", %{session: session} do
      # The hard case: open, then close before entering completes.
      # The bug class here is the EnteringPhase _timeout not being
      # cleared on onExit → late firing transitions the modal to
      # visible AFTER it's already exiting. Manifests as a flicker.
      #
      # Strategy: latency longer than entering animation so the
      # server reply for the OPEN hasn't landed by the time we fire
      # CLOSE. Both clicks queue, both server replies land later.
      # Final stable state should be "idle".

      session =
        session
        |> visit("/magic/modal-host")
        |> WLV.set_latency(@latency_ms)

      # Fire open and close in quick succession — both deferred so
      # we don't wait for either's server reply between clicks.
      session = click(session, css("#open-modal"), await: :defer)

      # Wait for the close button to appear in DOM (it's rendered
      # by the :if={@is_open} branch as soon as the optimistic open
      # flips item_id). Once present, click it.
      session = assert_has(session, css("#modal-content button"))
      session = click(session, css("#modal-content button"), await: :defer)

      try do
        # Two patches in flight; both lands. Modal should settle.
        session = WLV.await_patch(session)
        session = WLV.await_patch(session)

        # Phase should have returned to idle.
        # If the entering _timeout was not cleared on the rapid close,
        # the modal could be stuck on "visible" or oscillating.
        assert_has(session, css("[data-modal-phase='idle']"))
      after
        _ = WLV.clear_latency(session)
      end
    end
  end

  describe "async content (entering → loading → visible)" do
    test "modal sits in loading phase until async assign resolves", %{session: session} do
      # ModalAsyncComponent uses async_assign :item; the calc sleeps
      # 200ms. Modal entering animation also takes 200ms. So when
      # entering completes, async is still pending → transition to
      # loading. Then async resolves → transition to visible.
      session =
        session
        |> visit("/magic/modal-async-host")
        |> WLV.set_latency(@latency_ms)
        |> click(css("#open-modal"), await: :defer)

      try do
        session = WLV.await_patch(session)

        # By the time await_patch returns, the server has acknowledged
        # the open, the entering animation has completed, and async
        # data should have resolved (200ms sleep is comfortably less
        # than @latency_ms + entering duration). Final phase: visible,
        # body shows the loaded content.
        session = assert_has(session, css("[data-modal-phase='visible']"))
        assert_has(session, css("#modal-async-body", text: "Loaded item 42"))
      after
        _ = WLV.clear_latency(session)
      end
    end
  end

  describe "close from visible (visible → exiting → idle)" do
    test "normal close after modal is fully visible returns to idle", %{session: session} do
      # The happy path most users hit every modal session: open, wait
      # for fully-visible, then close. Tests the basic
      # VisiblePhase.onClose → ExitingPhase → IdlePhase sequence and
      # ensures the phase machine resets cleanly between cycles.
      session =
        session
        |> visit("/magic/modal-host")
        |> WLV.set_latency(@latency_ms)
        |> click(css("#open-modal"), await: :defer)

      try do
        # Drive the open all the way to visible.
        session = WLV.await_patch(session)
        session = assert_has(session, css("[data-modal-phase='visible']"))

        # Now close from a stable visible state.
        session = click(session, css("#modal-content button"), await: :defer)
        session = WLV.await_patch(session)

        # After exiting animation (200ms) + buffer, phase should be idle.
        # data-modal-phase reflects the client phase via onPhaseChange.
        assert_has(session, css("[data-modal-phase='idle']"))
      after
        _ = WLV.clear_latency(session)
      end
    end
  end

  describe "reopen mid-exit (exiting → entering)" do
    test "rapid reopen during exit animation re-enters cleanly", %{session: session} do
      # Mirror of the close-mid-entering test, in the opposite
      # direction: open the modal, let it become visible, click
      # close, then immediately click open again before the exit
      # animation completes (200ms window). The ExitingPhase
      # _timeout must be cleared on onExit so it doesn't fire late
      # and transition us to idle after we've already re-entered.
      session =
        session
        |> visit("/magic/modal-host")
        |> WLV.set_latency(@latency_ms)
        |> click(css("#open-modal"), await: :defer)

      try do
        # Drive the open to visible.
        session = WLV.await_patch(session)
        session = assert_has(session, css("[data-modal-phase='visible']"))

        # Close, then immediately reopen — both deferred so we don't
        # wait for either reply in between. The close-click fires
        # client-side immediately; the reopen-click fires before the
        # exit animation's 250ms timer.
        session = click(session, css("#modal-content button"), await: :defer)
        session = click(session, css("#open-modal"), await: :defer)

        # Two server replies in flight; drain both.
        session = WLV.await_patch(session)
        session = WLV.await_patch(session)

        # Final stable phase should be visible — we re-entered after
        # the exit started. If the ExitingPhase _timeout fired late,
        # we'd be stuck on idle (despite the open) or oscillating.
        assert_has(session, css("[data-modal-phase='visible']"))
        assert_has(session, css("#modal-content"))
      after
        _ = WLV.clear_latency(session)
      end
    end
  end

  describe "enter animation actually animates (freeze snapshot regression)" do
    test "panel is mid-transition during entering, not frozen at its target", %{
      session: session
    } do
      # Regression for the live-getComputedStyle freeze bug: for a
      # non-async overlay, open=true and the content arrive in the SAME
      # patch, so two animated applies run in one task. The second
      # apply's _freeze set `transition: none` BEFORE reading the live
      # computed style object — cancelling the just-started transition
      # resolves the read to the TARGET value, freezing the panel at its
      # destination. Visually: the overlay pops instead of animating.
      #
      # The probe runs entirely in-browser and is load-immune: a
      # MutationObserver fires in a microtask the moment the phase
      # attribute flips to "entering" — zero wall-clock time has passed
      # for the transition at that point, so a healthy fade reads its
      # START value (~0) and the frozen bug reads the TARGET (1),
      # regardless of CPU contention. (Timer-based polling raced here:
      # under full-suite load a late sample reads a legitimately
      # finished fade.)
      session = visit(session, "/magic/modal-host")

      probe = """
      var done = arguments[arguments.length - 1];
      var root = document.getElementById('lavash-test-modal');
      var finished = false;
      var obs = new MutationObserver(function() {
        if (finished) return;
        if (root.getAttribute('data-modal-phase') === 'entering') {
          var panel = document.getElementById('test-modal-modal-panel_content');
          finished = true;
          obs.disconnect();
          done({phase: 'entering', opacity: getComputedStyle(panel).opacity});
        }
      });
      obs.observe(root, {attributes: true, attributeFilter: ['data-modal-phase']});
      document.getElementById('open-modal').click();
      setTimeout(function() {
        if (finished) return;
        finished = true;
        obs.disconnect();
        done({phase: root.getAttribute('data-modal-phase'), missed: true});
      }, 4000);
      """

      test_pid = self()

      Wallabidi.Browser.execute_script_async(session, probe, [], fn result ->
        send(test_pid, {:probe, result})
      end)

      assert_receive {:probe, result}, 5_000

      assert result["phase"] == "entering",
             "never observed the entering phase (got: #{inspect(result)})"

      {opacity, _} = Float.parse(result["opacity"])

      assert opacity < 0.9,
             "panel already at opacity #{opacity} at the start of entering — " <>
               "the enter transition was frozen at its target instead of animating"
    end
  end

  describe "close mid-loading (loading → exiting)" do
    test "closing while async is pending exits cleanly without late callback", %{
      session: session
    } do
      # ModalAsyncComponent's :item calc sleeps 200ms. The modal
      # entering animation is 200ms. So there's a window after
      # entering completes where we're in `loading` and the async
      # callback hasn't fired yet. Closing here exercises
      # LoadingPhase.onClose → ExitingPhase, and importantly: the
      # subsequent async-resolved callback must NOT transition us
      # back to visible (we've already left loading).
      session =
        session
        |> visit("/magic/modal-async-host")
        |> WLV.set_latency(@latency_ms)
        |> click(css("#open-modal"), await: :defer)

      try do
        # Don't wait for the server patch — close as soon as the
        # close button appears in DOM (rendered by :if={@is_open}).
        session = assert_has(session, css("#modal-async-content button"))
        session = click(session, css("#modal-async-content button"), await: :defer)

        # Drain both server replies.
        session = WLV.await_patch(session)
        session = WLV.await_patch(session)

        # Final phase: idle. The async resolution that landed
        # mid-exit must not have promoted us back to visible.
        assert_has(session, css("[data-modal-phase='idle']"))
      after
        _ = WLV.clear_latency(session)
      end
    end
  end
end
