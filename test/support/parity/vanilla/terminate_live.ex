defmodule Lavash.Parity.Vanilla.TerminateLive do
  @moduledoc """
  Vanilla `Phoenix.LiveView` reference for the terminate parity
  suite.

  `terminate/2` is an optional `Phoenix.LiveView` callback. Most
  LiveViews don't define it; it's useful for cleanup on process
  exit (close a port, unsubscribe from an external source, write
  to telemetry).

  ## What this fixture does

  `terminate/2` writes `{:terminated, reason}` to ETS keyed by
  the LiveView's `socket.id`. The test reads the table after the
  process exits to verify the callback ran with the expected
  reason.

  ## Note on format_status/2

  `Phoenix.LiveView` doesn't expose `format_status/2` as a
  per-view callback — the LV runs inside
  `Phoenix.LiveView.Channel`, which has its own
  `format_status/2`. A user-supplied `def format_status/2` on the
  LV module wouldn't be called. So this parity suite covers only
  `terminate/2`.
  """
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :counter, 0)}
  end

  @impl true
  def handle_event("inc", _params, socket) do
    {:noreply, update(socket, :counter, &(&1 + 1))}
  end

  @impl true
  def terminate(reason, socket) do
    Lavash.Parity.TerminateProbe.record(socket.id, reason)
    :ok
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="terminate-vanilla">
      <p id="counter">{@counter}</p>
      <p id="socket-id">{@socket.id}</p>
      <button id="inc" phx-click="inc">+1</button>
    </div>
    """
  end
end
