defmodule Lavash.Test.Magic.SocketCounterLive do
  @moduledoc """
  Fixture: a `from: :socket` counter — the state kind that rides the
  layer-2 reconnect cache (`_lavash_sync` push → `_lavash_state`
  connect param). Used by the crash-remount e2e (issue #76) to prove
  socket-backed state survives the LiveView process dying while
  ephemeral state resets.
  """
  use Lavash.LiveView

  state :count, :integer, from: :socket, default: 0, optimistic: true

  actions do
    action :bump do
      set :count, rx(@count + 1)
    end
  end

  template do
    ~H"""
    <div>
      <span id="count">{@count}</span>
      <button id="bump" phx-click="bump">+</button>
    </div>
    """
  end
end
