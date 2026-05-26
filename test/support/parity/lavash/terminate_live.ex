defmodule Lavash.Parity.Lavash.TerminateLive do
  @moduledoc """
  Lavash DSL expression of the terminate parity suite — paired
  with `Lavash.Parity.Vanilla.TerminateLive`.

  ## No new DSL surface

  `terminate/2` is an optional `Phoenix.LiveView` callback.
  `use Lavash.LiveView` does `use Phoenix.LiveView` under the
  hood, so the user can define it directly and it works
  unchanged. No declarative wrapper is needed — `terminate/2` is
  escape-hatch territory (process cleanup) where the imperative
  shape is the right shape.

  This parity test exists to lock that down: if lavash ever grows
  a transformer that shadows `terminate/2` (e.g. by emitting its
  own non-overridable definition), this test catches it.

  ## What's not in this fixture

  `format_status/2` is intentionally absent. `Phoenix.LiveView`
  doesn't expose it as a per-view callback — the LV process runs
  inside `Phoenix.LiveView.Channel`, which has its own
  `format_status/2`. A user-supplied `def format_status/2` on the
  LV module would never be invoked.
  """
  use Lavash.LiveView

  state :counter, :integer, default: 0, optimistic: true

  actions do
    action :inc do
      set :counter, rx(@counter + 1)
    end
  end

  @impl Phoenix.LiveView
  def terminate(reason, socket) do
    Lavash.Parity.TerminateProbe.record(socket.id, reason)
    :ok
  end

  template do
    ~H"""
    <div id="terminate-lavash">
      <p id="counter">{@counter}</p>
      <p id="socket-id">{@socket.id}</p>
      <button id="inc" phx-click="inc">+1</button>
    </div>
    """
  end
end
