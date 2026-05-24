defmodule Lavash.IntegrationCase do
  @moduledoc """
  Per-test case for browser-driven integration tests.

  Boots a Wallabidi session against `Lavash.TestEndpoint` (running at
  `LAVASH_TEST_PORT`, default 4002) using the Lightpanda driver. The endpoint
  is started by `test/test_helper.exs` when the `e2e` tag is included or when
  `LAVASH_E2E=1` is set.

  Tag your test module with:

      @moduletag :e2e

  Then write:

      use Lavash.IntegrationCase, async: false

      test "counter increments on click", %{session: session} do
        session
        |> visit("/counter")
        |> click(button("Increment"))
        |> assert_has(css("[data-lavash-display='count']", text: "1"))
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use Wallabidi.DSL

      import Wallabidi.Browser
      import Wallabidi.Query

      @moduletag :e2e
    end
  end

  setup tags do
    metadata = %{}

    {:ok, session} =
      Wallabidi.start_session(
        metadata: metadata,
        max_wait_time: tags[:wallabidi_timeout] || 5_000
      )

    on_exit(fn ->
      Wallabidi.end_session(session)
    end)

    {:ok, session: session}
  end
end
