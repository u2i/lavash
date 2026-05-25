import Config

# Use an isolated on-disk SQLite database per test process so the schema
# from migrations can be initialized once and reused.
config :demo, Demo.Repo,
  database: Path.expand("../demo_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :demo, DemoWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "1ETs6rqwWa6XCbCAnjkOPoXETEKqt9R2Zt0MBVIvf23spuxcMgsgO5O/6vD7l3gf",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
