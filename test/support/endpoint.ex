defmodule Lavash.TestEndpoint do
  use Phoenix.Endpoint, otp_app: :lavash

  @session_options [
    store: :cookie,
    key: "_lavash_test_key",
    signing_salt: "test_salt",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false
  )

  # Serve phoenix.js / phoenix_live_view.js straight from the deps so
  # integration tests have a working LiveSocket without a build step.
  plug(Plug.Static,
    at: "/assets/phoenix",
    from: {:phoenix, "priv/static"},
    gzip: false,
    only: ~w(phoenix.js phoenix.min.js)
  )

  plug(Plug.Static,
    at: "/assets/phoenix_live_view",
    from: {:phoenix_live_view, "priv/static"},
    gzip: false,
    only: ~w(phoenix_live_view.js phoenix_live_view.esm.js phoenix_live_view.min.js)
  )

  plug(Plug.Session, @session_options)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(Lavash.TestRouter)
end
