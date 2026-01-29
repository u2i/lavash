defmodule Lavash.Application do
  @moduledoc """
  OTP Application for Lavash.

  This module provides a minimal OTP application for Lavash, primarily to enable
  runtime configuration via `Application.get_env/2`.

  Currently, Lavash uses application configuration for:
  - `:pubsub` - The PubSub module for cross-process resource invalidation (see `Lavash.PubSub`)

  Example configuration:

      config :lavash, pubsub: MyApp.PubSub
  """

  use Application

  @impl true
  def start(_type, _args) do
    # Lavash doesn't supervise any processes currently, but the Application module
    # is required for runtime configuration support.
    children = []

    opts = [strategy: :one_for_one, name: Lavash.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
