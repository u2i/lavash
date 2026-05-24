defmodule Lavash.Integration.CalculationsTest do
  @moduledoc """
  Reactive calculations — same observable contract across the DSL-driven
  /magic/* path (where `calculate :name, rx(...)` does the work) and the
  /explicit/* path (where derived values are recomputed manually). Both
  produce the same DOM after every state change.
  """
  use Lavash.IntegrationCase, async: false

  for {label, prefix} <- [{"magic", "/magic"}, {"explicit", "/explicit"}] do
    @prefix prefix

    describe "calculations chain (#{label})" do
      test "downstream calculations update when their dependency changes", %{session: session} do
        session
        |> visit(@prefix <> "/chained")
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

      test "transitive chains stay consistent across multiple bumps", %{session: session} do
        session
        |> visit(@prefix <> "/chained")
        |> click(css("#inc"))
        |> click(css("#inc"))
        |> click(css("#inc"))
        |> assert_has(css("#count", text: "4"))
        |> assert_has(css("#doubled", text: "8"))
        |> assert_has(css("#quadrupled", text: "16"))
        |> assert_has(css("#octupled", text: "32"))
      end

      test "ephemeral-state chains also propagate after click", %{session: session} do
        session
        |> visit(@prefix <> "/chained-ephemeral")
        |> assert_has(css("#base", text: "1"))
        |> assert_has(css("#octupled", text: "8"))
        |> click(css("#inc"))
        |> assert_has(css("#base", text: "2"))
        |> assert_has(css("#octupled", text: "16"))
      end
    end
  end

  describe "calculations chain (magic-only)" do
    # The magic path supports async: true on a calculation; the explicit
    # equivalent uses assign_async/3 which has different semantics
    # (loading/ok states surface differently). Asserted on /magic only.
    test "async calculations resolve to a steady value", %{session: session} do
      session
      |> visit("/magic/async-chain")
      |> assert_has(css("#count", text: "1"))
      |> assert_has(css("#doubled", text: "2"))
      |> assert_has(css("#quadrupled", text: "4"))
    end
  end
end
