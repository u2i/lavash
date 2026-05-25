defmodule Lavash.Parity.Vanilla.HandleInfoLive do
  @moduledoc """
  Vanilla `Phoenix.LiveView` reference for the handle_info/2
  parity suite. Exercises:

    * a self-scheduled tick via Process.send_after
    * a generic message dispatched via send(self(), msg)
    * PubSub broadcast received via handle_info

  PubSub round-trip is exercised by subscribing to a topic on
  mount and broadcasting from a handle_event in the same module.
  """
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Lavash.PubSub, "parity:handle_info")
    end

    socket =
      socket
      |> assign(:ticks, 0)
      |> assign(:last_msg, nil)
      |> assign(:broadcasts, 0)

    {:ok, socket}
  end

  @impl true
  def handle_event("schedule_tick", _params, socket) do
    Process.send_after(self(), :tick, 50)
    {:noreply, socket}
  end

  @impl true
  def handle_event("self_send", _params, socket) do
    send(self(), {:custom_msg, "hello"})
    {:noreply, socket}
  end

  @impl true
  def handle_event("broadcast", _params, socket) do
    Phoenix.PubSub.broadcast(Lavash.PubSub, "parity:handle_info", :pinged)
    {:noreply, socket}
  end

  @impl true
  def handle_info(:tick, socket) do
    {:noreply, update(socket, :ticks, &(&1 + 1))}
  end

  @impl true
  def handle_info({:custom_msg, msg}, socket) do
    {:noreply, assign(socket, :last_msg, msg)}
  end

  @impl true
  def handle_info(:pinged, socket) do
    {:noreply, update(socket, :broadcasts, &(&1 + 1))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="handle-info-vanilla">
      <p id="ticks">{@ticks}</p>
      <p id="last-msg">{@last_msg || "(none)"}</p>
      <p id="broadcasts">{@broadcasts}</p>

      <button id="schedule" phx-click="schedule_tick">schedule</button>
      <button id="self-send" phx-click="self_send">self send</button>
      <button id="broadcast" phx-click="broadcast">broadcast</button>
    </div>
    """
  end
end
