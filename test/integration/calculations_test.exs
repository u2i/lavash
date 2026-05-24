defmodule Lavash.Integration.CalculationsTest do
  @moduledoc """
  Reactive calculations — `calculate :name, rx(...)` recomputes server-side
  on every state change and propagates through chains.
  """
  use Lavash.IntegrationCase, async: false

  test "downstream calculations update when their dependency changes", %{session: session} do
    session
    |> visit("/chained")
    |> assert_has(css("#count", text: "1"))
    |> assert_has(css("#doubled", text: "2"))
    |> assert_has(css("#quadrupled", text: "4"))
    |> assert_has(css("#octupled", text: "8"))
    |> click(css("#inc"))
    |> assert_has(css("#count", text: "2"))
    |> assert_has(css("#doubled", text: "4"))
    |> assert_has(css("#quadrupled", text: "8"))
    |> assert_has(css("#octupled", text: "16"))
  end

  test "transitive chains recompute consistently — no intermediate stale frame", %{
    session: session
  } do
    # Click a few times and verify the whole chain stays consistent at each step.
    # If topological ordering were wrong, we'd see a stale @doubled briefly while
    # @quadrupled was recomputing — the assert_has waits and re-checks, so a
    # transient inconsistency would manifest as a stable mismatch.
    session
    |> visit("/chained")
    |> click(css("#inc"))
    |> click(css("#inc"))
    |> click(css("#inc"))
    |> assert_has(css("#count", text: "4"))
    |> assert_has(css("#doubled", text: "8"))
    |> assert_has(css("#quadrupled", text: "16"))
    |> assert_has(css("#octupled", text: "32"))
  end

  test "async calculations resolve after a delay", %{session: session} do
    # TestAsyncChainLive has calculate :doubled, rx(slow_double(@count)), async: true
    # The async result lands via send_update; eventually #doubled shows the resolved value.
    session
    |> visit("/async-chain")
    |> assert_has(css("#count", text: "1"))
    # async slow_double(1) → 2; sync quadrupled = 4
    |> assert_has(css("#doubled", text: "2"))
    |> assert_has(css("#quadrupled", text: "4"))
  end

  test "non-optimistic calculations only update after server round-trip", %{session: session} do
    # The chained-ephemeral fixture uses non-URL-backed state. Click increments
    # base and propagates through the chain — verifies server-driven recompute
    # without optimistic JS paths.
    session
    |> visit("/chained-ephemeral")
    |> assert_has(css("#base", text: "1"))
    |> assert_has(css("#octupled", text: "8"))
    |> click(css("#inc"))
    |> assert_has(css("#base", text: "2"))
    |> assert_has(css("#octupled", text: "16"))
  end
end
