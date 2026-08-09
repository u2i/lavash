defmodule Lavash.Integration.DependentSelectTest do
  @moduledoc """
  Dependent selects: one select's value determines another select's
  option list, in both flavors (see the DependentSelectLive fixture):

  - optimistic — the option list is a transpiled defrx calc rendered by
    a subtree derive; it must swap client-side in the same task as the
    change event, before any server reply can exist.
  - non-optimistic — the same calc marked `optimistic: false`; the swap
    must NOT happen synchronously and must arrive with the server
    render after the round-trip.

  ## Why async: false

  Uses the LiveView latency simulator (sessionStorage on the shared
  browser session) to make "before the server replied" a wide,
  reliable window.
  """
  use Lavash.IntegrationCase, async: false

  alias Wallabidi.LiveView, as: WLV

  @latency_ms 400

  test "optimistic swaps synchronously; non-optimistic waits for the server", %{
    session: session
  } do
    session =
      session
      |> visit("/magic/dependent-select")
      |> WLV.set_latency(@latency_ms)

    # Phase 1 (in-browser, synchronous): change the country and sample
    # both region selects in the same task — zero server involvement
    # possible at that point.
    probe = """
    var done = arguments[arguments.length - 1];
    var texts = function(sel) {
      return Array.prototype.map.call(sel.options, function(o) { return o.text.trim(); });
    };
    var start = performance.now();
    (function ready() {
      var main = document.querySelector('[data-phx-main]');
      var hookEl = document.querySelector("[phx-hook='LavashOptimistic']");
      var connected = main && main.classList.contains('phx-connected');
      var mounted = hookEl && hookEl.__lavash_hook__;
      if (!(connected && mounted)) {
        if (performance.now() - start > 5000) {
          done({timeout: true, connected: !!connected, hookEl: !!hookEl,
                mounted: !!mounted, country: !!document.getElementById('country'),
                hooks: Array.prototype.map.call(document.querySelectorAll('[phx-hook]'),
                  function(e) { return e.getAttribute('phx-hook'); })});
          return;
        }
        setTimeout(ready, 50);
        return;
      }
      var country = document.getElementById('country');
      var fast = document.getElementById('fast-region');
      var slow = document.getElementById('slow-region');
      var before = { fast: texts(fast), slow: texts(slow) };
      country.value = 'CA';
      country.dispatchEvent(new Event('input', {bubbles: true}));
      country.dispatchEvent(new Event('change', {bubbles: true}));
      var sync = { fast: texts(fast), slow: texts(slow) };
      done({before: before, sync: sync});
    })();
    """

    test_pid = self()

    Wallabidi.Browser.execute_script_async(session, probe, [], fn result ->
      send(test_pid, {:probe, result})
    end)

    assert_receive {:probe, result}, 10_000

    refute result["timeout"], "probe timed out waiting for readiness: #{inspect(result)}"

    # Both start with the US list.
    assert result["before"]["fast"] == ["California", "Texas"]
    assert result["before"]["slow"] == ["California", "Texas"]

    # Optimistic: swapped in the same task as the change event.
    assert result["sync"]["fast"] == ["Ontario", "Quebec"],
           "optimistic region options did not swap synchronously: #{inspect(result["sync"])}"

    # Non-optimistic: unchanged before the server has replied.
    assert result["sync"]["slow"] == ["California", "Texas"],
           "non-optimistic options swapped before the server round-trip: #{inspect(result["sync"])}"

    try do
      # Phase 2: after the server round-trip, the non-optimistic select
      # catches up (and the optimistic one must not regress).
      poll = """
      var done = arguments[arguments.length - 1];
      var texts = function(sel) {
        return Array.prototype.map.call(sel.options, function(o) { return o.text.trim(); });
      };
      var start = performance.now();
      (function check() {
        var slow = texts(document.getElementById('slow-region'));
        if (slow[0] === 'Ontario' || performance.now() - start > 6000) {
          done({slow: slow, fast: texts(document.getElementById('fast-region'))});
        } else {
          setTimeout(check, 100);
        }
      })();
      """

      Wallabidi.Browser.execute_script_async(session, poll, [], fn result ->
        send(test_pid, {:poll, result})
      end)

      assert_receive {:poll, after_server}, 10_000

      assert after_server["slow"] == ["Ontario", "Quebec"],
             "non-optimistic options never swapped after the server round-trip"

      assert after_server["fast"] == ["Ontario", "Quebec"]
    after
      _ = WLV.clear_latency(session)
    end
  end
end
