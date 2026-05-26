# Lavash's behavior depends on browser-side JS (optimistic updates,
# SyncedVar merge walker, modal phase machine, data-lavash-*
# annotations). The unit tests verify the Elixir side, but only the
# browser e2e tests verify the JS actually does what it should — so
# they run by default.
#
# Opt-out:
#   LAVASH_NO_E2E=1 mix test          # skip browser tests
#   mix test --exclude e2e            # same, via ExUnit
e2e? = System.get_env("LAVASH_NO_E2E") != "1"

http_port = String.to_integer(System.get_env("LAVASH_TEST_PORT", "4002"))

Application.put_env(:lavash, Lavash.TestEndpoint,
  url: [host: "localhost"],
  http: [port: http_port],
  secret_key_base: String.duplicate("a", 64),
  live_view: [signing_salt: "test_salt"],
  render_errors: [formats: [html: Lavash.TestErrorView]],
  pubsub_server: Lavash.PubSub,
  server: e2e?
)

Application.put_env(:phoenix, :json_library, Jason)

{:ok, _} =
  Supervisor.start_link(
    [
      {Phoenix.PubSub, name: Lavash.PubSub},
      Lavash.TestEndpoint
    ],
    strategy: :one_for_one
  )

if e2e? do
  # Auto-discover Chrome on macOS if neither WALLABIDI_CHROME_PATH
  # nor WALLABIDI_CHROME_URL is set. Wallabidi looks for one of
  # these to know which Chrome to drive; setting CHROME_PATH points
  # it at a local binary, CHROME_URL points it at a remote CDP
  # endpoint (e.g. `chrome:9222`).
  if !System.get_env("WALLABIDI_CHROME_PATH") and !System.get_env("WALLABIDI_CHROME_URL") do
    mac_chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

    if File.exists?(mac_chrome) do
      System.put_env("WALLABIDI_CHROME_PATH", mac_chrome)
    end
  end

  Application.put_env(:wallabidi, :driver, :chrome_cdp)
  Application.put_env(:wallabidi, :base_url, "http://localhost:#{http_port}")
  Application.put_env(:wallabidi, :endpoint, Lavash.TestEndpoint)

  {:ok, _} = Application.ensure_all_started(:wallabidi)
end

ExUnit.start(exclude: if(e2e?, do: [], else: [:e2e]))
