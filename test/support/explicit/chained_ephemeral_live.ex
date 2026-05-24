defmodule Lavash.Test.Explicit.ChainedEphemeralLive do
  @moduledoc """
  Plain Phoenix.LiveView counterpart to
  Lavash.Test.Magic.ChainedEphemeralLive. Same chain over ephemeral state.
  """
  use Phoenix.LiveView

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, recompute(assign(socket, base: 1))}
  end

  @impl Phoenix.LiveView
  def handle_event("increment", _, socket) do
    {:noreply, recompute(update(socket, :base, &(&1 + 1)))}
  end

  defp recompute(socket) do
    base = socket.assigns.base
    doubled = base * 2
    quadrupled = doubled * 2
    octupled = quadrupled * 2

    assign(socket,
      doubled: doubled,
      quadrupled: quadrupled,
      octupled: octupled
    )
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div>
      <span id="base">{@base}</span>
      <span id="doubled">{@doubled}</span>
      <span id="quadrupled">{@quadrupled}</span>
      <span id="octupled">{@octupled}</span>
      <button id="inc" phx-click="increment">+</button>
    </div>
    """
  end
end
