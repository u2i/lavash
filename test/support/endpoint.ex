defmodule Lavash.TestEndpoint do
  use Phoenix.Endpoint, otp_app: :lavash

  @session_options [
    store: :cookie,
    key: "_lavash_test_key",
    signing_salt: "test_salt",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false

  plug Plug.Session, @session_options

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason

  plug Lavash.TestRouter
end
