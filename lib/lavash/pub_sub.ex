defmodule Lavash.PubSub do
  @moduledoc """
  PubSub integration for cross-process resource invalidation.

  When a Lavash form submits successfully, it broadcasts to all subscribers
  watching that resource. Any LiveView or component with a `read` for that
  resource will automatically invalidate and refetch.

  ## Configuration

  Configure your app's PubSub in config:

      config :lavash, pubsub: MyApp.PubSub

  ## How it works

  1. On mount, Lavash subscribes to topics for each resource in `read` declarations
  2. On successful form submit, Lavash broadcasts to the resource's topic
  3. All subscribers receive the broadcast and invalidate affected fields

  Topics are named `"lavash:resource:<ModuleName>"`, e.g. `"lavash:resource:MyApp.Product"`.
  """

  @doc """
  Returns the configured PubSub module, or nil if not configured.
  """
  def pubsub do
    Application.get_env(:lavash, :pubsub)
  end

  @doc """
  Subscribe the current process to invalidation events for a resource.
  """
  def subscribe(resource) when is_atom(resource) do
    case pubsub() do
      nil -> :ok
      pubsub_mod -> Phoenix.PubSub.subscribe(pubsub_mod, topic(resource))
    end
  end

  @doc """
  Broadcast a resource mutation to all subscribers.
  """
  def broadcast(resource) when is_atom(resource) do
    case pubsub() do
      nil -> :ok
      pubsub_mod -> Phoenix.PubSub.broadcast(pubsub_mod, topic(resource), {:lavash_invalidate, resource})
    end
  end

  @doc """
  Returns the topic name for a resource.
  """
  def topic(resource) when is_atom(resource) do
    "lavash:resource:#{resource}"
  end
end
