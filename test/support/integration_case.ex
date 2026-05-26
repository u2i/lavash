defmodule Lavash.IntegrationCase do
  @moduledoc """
  Per-test case for browser-driven e2e tests — the half of the
  test suite that proves the JS client actually works.

  Boots a Wallabidi session against `Lavash.TestEndpoint` (running
  at `LAVASH_TEST_PORT`, default 4002) using Chrome via the CDP
  driver. The endpoint is started by `test/test_helper.exs`
  unconditionally; e2e tests run by default and skip only when
  `LAVASH_NO_E2E=1` is set (or `mix test --exclude e2e` is passed).

  ## Why this matters

  Lavash's value prop — optimistic UI, modal phase machines,
  client-side rx evaluation, `data-lavash-*` DOM updates — is
  ~half JavaScript. Unit tests verify the Elixir transformers,
  but only browser tests verify the JS actually does what the
  Elixir said it should. They're not optional; they're the
  contract.

  ## Usage

  Tag your test module with:

      @moduletag :e2e

  (Done automatically by `use Lavash.IntegrationCase`.)

      use Lavash.IntegrationCase, async: false

      test "counter increments on click", %{session: session} do
        session
        |> visit("/counter")
        |> click(button("Increment"))
        |> assert_has(css("[data-lavash-display='count']", text: "1"))
      end

  ## Chrome discovery

  Wallabidi needs to know which Chrome to drive. Set one of:

    * `WALLABIDI_CHROME_PATH` — path to a local Chrome binary
    * `WALLABIDI_CHROME_URL` — remote CDP endpoint (e.g. `chrome:9222`)

  Without one of these the e2e suite fails at startup with
  `Wallabidi.DependencyError: Chrome not found`.
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
