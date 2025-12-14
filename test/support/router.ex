defmodule Lavash.TestRouter do
  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :put_root_layout, html: {Lavash.TestLayouts, :root}
    plug :put_secure_browser_headers
  end

  scope "/", Lavash do
    pipe_through :browser

    live "/counter", TestCounterLive
    live "/typed", TestTypedLive
    live "/chained", TestChainedDerivedLive
    live "/chained-ephemeral", TestChainedEphemeralLive
    live "/async-chain", TestAsyncChainLive
  end
end
