Application.put_env(:lavash, Lavash.TestEndpoint,
  url: [host: "localhost"],
  secret_key_base: String.duplicate("a", 64),
  live_view: [signing_salt: "test_salt"],
  render_errors: [formats: [html: Lavash.TestErrorView]],
  pubsub_server: Lavash.PubSub,
  server: false
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

ExUnit.start()
