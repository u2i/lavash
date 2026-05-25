defmodule Lavash.Parity.Vanilla.HandleEventLive do
  @moduledoc """
  Vanilla `Phoenix.LiveView` reference implementation for the
  handle_event parity suite. Exercises:

    * basic noreply update
    * phx-value-* params being passed through to handle_event/3
    * push_event/3
    * push_patch/2
    * push_navigate/2 + redirect/2
    * {:reply, payload, socket} return shape
    * a simple authorization gate (no-op when not allowed)
  """
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:count, 0)
      |> assign(:last_event, nil)
      |> assign(:is_admin, true)

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("inc", _params, socket) do
    {:noreply, update(socket, :count, &(&1 + 1))}
  end

  @impl true
  def handle_event("bump_by", %{"amount" => amount}, socket) do
    {:noreply, update(socket, :count, &(&1 + String.to_integer(amount)))}
  end

  @impl true
  def handle_event("track", %{"label" => label}, socket) do
    {:noreply, assign(socket, :last_event, label)}
  end

  @impl true
  def handle_event("push_demo", _params, socket) do
    {:noreply, push_event(socket, "client_pong", %{at: "server"})}
  end

  @impl true
  def handle_event("patch_demo", _params, socket) do
    {:noreply, push_patch(socket, to: "/parity/vanilla/handle_event?via=patch")}
  end

  @impl true
  def handle_event("navigate_demo", _params, socket) do
    {:noreply, push_navigate(socket, to: "/parity/vanilla/handle_event_landing")}
  end

  @impl true
  def handle_event("redirect_demo", _params, socket) do
    {:noreply, redirect(socket, to: "/parity/vanilla/handle_event_landing")}
  end

  @impl true
  def handle_event("toggle_admin", _params, socket) do
    {:noreply, update(socket, :is_admin, &(!&1))}
  end

  @impl true
  def handle_event("guarded_inc", _params, socket) do
    if socket.assigns.is_admin do
      {:noreply, update(socket, :count, &(&1 + 1))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="handle-event-vanilla">
      <p id="count">{@count}</p>
      <p id="last-event">{@last_event || "(none)"}</p>
      <p id="is-admin">{to_string(@is_admin)}</p>

      <button id="inc" phx-click="inc">+1</button>
      <button id="bump-by" phx-click="bump_by" phx-value-amount="5">+5</button>
      <button id="track" phx-click="track" phx-value-label="howdy">track</button>
      <button id="push-demo" phx-click="push_demo">push</button>
      <button id="patch-demo" phx-click="patch_demo">patch</button>
      <button id="navigate-demo" phx-click="navigate_demo">navigate</button>
      <button id="redirect-demo" phx-click="redirect_demo">redirect</button>
      <button id="toggle-admin" phx-click="toggle_admin">toggle admin</button>
      <button id="guarded-inc" phx-click="guarded_inc">guarded +1</button>
    </div>
    """
  end
end

defmodule Lavash.Parity.Vanilla.HandleEventLandingLive do
  @moduledoc """
  Trivial landing target for navigate / redirect tests so the
  destination route actually mounts.
  """
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div id="handle-event-landing">landed</div>
    """
  end
end
