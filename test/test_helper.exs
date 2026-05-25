e2e? =
  Enum.any?(System.argv(), &(&1 in ["--include", "e2e"])) or System.get_env("LAVASH_E2E") == "1"

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
  Application.put_env(:wallabidi, :driver, :chrome_cdp)
  Application.put_env(:wallabidi, :base_url, "http://localhost:#{http_port}")
  Application.put_env(:wallabidi, :endpoint, Lavash.TestEndpoint)

  {:ok, _} = Application.ensure_all_started(:wallabidi)
end

ExUnit.start(exclude: [:e2e])
