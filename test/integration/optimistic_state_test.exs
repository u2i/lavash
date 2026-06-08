defmodule Lavash.Integration.OptimisticStateTest do
  @moduledoc """
  Optimistic state — fields declared `optimistic: true`. These tests assert
  the server-observable end state after a round-trip. The pre-round-trip
  client-side update (DOM patched within an animation frame) is covered by
  a JS-only test suite, since asserting "before the server reply arrives"
  requires more than a basic Wallabidi probe.
  """
  use Lavash.IntegrationCase, async: false

  test "optimistic scalar updates reach the server and re-render", %{session: session} do
    # TestDomDirectivesLive has state :n, :integer, ..., optimistic: true.
    session
    |> visit("/magic/dom-directives")
    |> click(css("#bump"))
    |> assert_has(css("p", text: "Count: 1"))
  end

  test "optimistic boolean toggles re-render correctly", %{session: session} do
    session
    |> visit("/magic/dom-directives")
    |> click(css("#toggle-flag"))
    |> assert_has(css("#toggle-target.on-class"))
  end

  test "URL-backed state hydrates from URL on mount", %{session: session} do
    # TestCounterLive's :count is from: :url. Survives reload (no reconnect
    # mid-test, but the next visit is a fresh page load).
    session
    |> visit("/magic/counter?count=42")
    |> assert_has(css("#count", text: "42"))
  end

  test "ephemeral state resets across full page reloads", %{session: session} do
    # bump increments :n. Reload should reset because :n is ephemeral.
    session
    |> visit("/magic/dom-directives")
    |> click(css("#bump"))
    |> assert_has(css("p", text: "Count: 1"))
    |> visit("/magic/dom-directives")
    |> assert_has(css("p", text: "Count: 0"))
  end

  test "multi-field optimistic updates apply together", %{session: session} do
    session
    |> visit("/magic/dom-directives")
    |> click(css("#bump"))
    |> click(css("#toggle-flag"))
    |> click(css("#toggle-three"))
    |> assert_has(css("p", text: "Count: 1"))
    |> assert_has(css("#toggle-target.on-class"))
    |> assert_has(css("#chip-three.selected"))
  end

  describe "transpiler edge cases (generated JS must parse + run in the browser)" do
    # These constructs previously emitted invalid/broken client JS that only
    # failed at prod esbuild. If the JS is wrong, the optimistic re-render
    # never patches the DOM and these assertions fail.

    test "?-suffixed nested key drives an optimistic :if", %{session: session} do
      session = visit(session, "/magic/transpiler-edge")
      refute Wallabidi.Browser.has?(session, css("#declared"))

      session
      |> click(css("#toggle-declared"))
      |> assert_has(css("#declared", text: "declared"))
    end

    test "empty-list comparison (!= []) drives an optimistic :if", %{session: session} do
      session = visit(session, "/magic/transpiler-edge")
      refute Wallabidi.Browser.has?(session, css("#has-findings"))

      session
      |> click(css("#add-finding"))
      |> assert_has(css("#has-findings", text: "Has findings: 1"))
    end

    test "optimistic :for with ?-suffixed loop-var fields re-renders", %{session: session} do
      session
      |> visit("/magic/transpiler-edge")
      |> assert_has(css("#repos .repo", text: "alpha: ready"))
      |> click(css("#add-repo"))
      |> assert_has(css("#repos .repo", text: "beta: pending"))
    end
  end
end
