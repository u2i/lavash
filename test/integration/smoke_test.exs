defmodule Lavash.Integration.SmokeTest do
  @moduledoc """
  Confirms the wallabidi + Lightpanda rig is wired up correctly.

  If this passes, the test endpoint is reachable, Lightpanda launched, and a
  Wallabidi session can drive a LiveView to completion. If this fails,
  everything else in `test/integration/` will too — fix this first.
  """
  use Lavash.IntegrationCase, async: false

  test "loads a fixture LiveView", %{session: session} do
    session
    |> visit("/magic/counter")
    |> assert_has(css("#count", text: "0"))
  end

  test "clicking the increment button updates the count", %{session: session} do
    session
    |> visit("/magic/counter")
    |> click(css("#inc"))
    |> assert_has(css("#count", text: "1"))
  end
end
