defmodule Lavash.Test.Explicit.ChainedEphemeralLive do
  @moduledoc """
  Counterpart to Lavash.Test.Magic.ChainedEphemeralLive using
  Lavash.LiveView.Explicit. Ephemeral state has no special handling
  in the explicit path — every state is just an assigned value that
  resets on remount.
  """
  use Lavash.LiveView.Explicit

  reactive do
    state :base, 1
    derive :doubled, rx(@base * 2)
    derive :quadrupled, rx(@doubled * 2)
    derive :octupled, rx(@quadrupled * 2)
  end

  @impl Phoenix.LiveView
  def handle_event("increment", _, socket) do
    {:noreply, put_state(socket, :base, &(&1 + 1))}
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
