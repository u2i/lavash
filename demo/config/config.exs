# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :demo,
  ecto_repos: [Demo.Repo],
  generators: [timestamp_type: :utc_datetime],
  ash_domains: [Demo.Catalog, Demo.Accounts],
  token_signing_secret: "super_secret_key_for_development_only_change_in_production"

# Configure Lavash PubSub for cross-process resource invalidation
config :lavash, pubsub: Demo.PubSub

# Write colocated hooks to assets/vendor so esbuild --watch detects changes
# This is needed for path dependencies (like lavash) during development
config :phoenix_live_view, :colocated_js,
  target_directory: Path.expand("../assets/vendor/phoenix-colocated", __DIR__)

# Configures the endpoint
config :demo, DemoWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: DemoWeb.ErrorHTML, json: DemoWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Demo.PubSub,
  live_view: [signing_salt: "31nKzofp"]

# Configure esbuild (the version is required)
# NODE_PATH includes build_path for colocated hooks from libraries
# --alias:lavash resolves to the library's priv/static for JS imports
config :esbuild,
  version: "0.17.11",
  demo: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=. --alias:lavash=../../priv/static/index.js),
    cd: Path.expand("../assets", __DIR__),
    env: %{
      # vendor/ contains phoenix-colocated (via :colocated_js config above)
      "NODE_PATH" =>
        Enum.join(
          [
            Path.expand("../deps", __DIR__),
            Path.expand("../assets/vendor", __DIR__)
          ],
          ":"
        )
    }
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.0.9",
  demo: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
