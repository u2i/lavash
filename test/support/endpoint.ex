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
    only: ~w(phoenix.js phoenix.min.js phoenix.mjs)
  )

  plug(Plug.Static,
    at: "/assets/phoenix_live_view",
    from: {:phoenix_live_view, "priv/static"},
    gzip: false,
    only: ~w(phoenix_live_view.js phoenix_live_view.esm.js phoenix_live_view.min.js)
  )

  # Lavash's own JS modules — served as native ES modules so the test layout
  # can <script type="module" import="...">. No bundler needed.
  plug(Plug.Static,
    at: "/assets/lavash",
    from: {:lavash, "priv/static"},
    gzip: false
  )

  # Per-test-module optimistic JS extracted by Phoenix.LiveView.ColocatedJS
  # at compile time. The manifest at /assets/phoenix-colocated/lavash/index.js
  # imports each module's optimistic_<hash>.js and re-exports them under a
  # named `optimistic` export. Layouts load it and assign to
  # window.Lavash.optimistic so the lavash JS pipeline can dispatch by
  # module name. Without this, hooks have empty fns and the optimistic
  # patch never runs — see #93/#94 for context.
  plug(Plug.Static,
    at: "/assets/phoenix-colocated/lavash",
    from: Path.join([Mix.Project.build_path(), "phoenix-colocated", "lavash"]),
    gzip: false
  )

  plug(Plug.Session, @session_options)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(Lavash.TestRouter)
end
