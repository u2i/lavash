defmodule Lavash.Integration.SmokeTest do
  @moduledoc """
  Confirms the wallabidi + Lightpanda rig is wired up correctly.

  If this passes, the test endpoint is reachable, Lightpanda launched, and a
  Wallabidi session can drive a LiveView to completion. If this fails,
  everything else in `test/integration/` will too — fix this first.

  Runs against both the DSL-flavored /magic/* path and the plain-Phoenix
  /explicit/* path so we know both rigs are alive.
  """
  use Lavash.IntegrationCase, async: false

  for {label, prefix} <- [{"magic", "/magic"}, {"explicit", "/explicit"}] do
    @prefix prefix

    describe "smoke (#{label})" do
      test "loads a fixture LiveView", %{session: session} do
        session
        |> visit(@prefix <> "/counter")
        |> assert_has(css("#count", text: "0"))
      end

      test "clicking the increment button updates the count", %{session: session} do
        session
        |> visit(@prefix <> "/counter")
        |> click(css("#inc"))
        |> assert_has(css("#count", text: "1"))
      end
    end
  end
end
