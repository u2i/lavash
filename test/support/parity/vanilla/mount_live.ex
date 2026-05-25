defmodule Lavash.Parity.Vanilla.MountLive do
  @moduledoc """
  Vanilla `Phoenix.LiveView` reference for the mount/3 parity suite.

  Exercises the common shapes a real LV mount does:

    * literal defaults via assign/3
    * URL params via Map.get(params, ...)
    * session values
    * a non-DB computed assign (DB lookups would need a fake repo;
      tested separately under reads via Ash in another feature)
    * connected?/1 branching (no-op during static render, real
      subscription after the LiveView socket connects)
    * temporary_assigns and a custom layout option in the return
  """
  use Phoenix.LiveView

  @impl true
  def mount(params, session, socket) do
    # Default + URL-param state
    initial_count =
      case Map.get(params, "count") do
        nil -> 0
        s -> String.to_integer(s)
      end

    # Session-derived state
    handle = Map.get(session, "handle", "guest")

    # Computed initial state (here: derived from a param + literal)
    greeting = "Hello, " <> handle

    # connected?/1 differentiates static render from live socket.
    # In a real app this is where you'd subscribe / schedule timers.
    connected_at =
      if connected?(socket), do: System.system_time(:second), else: nil

    socket =
      socket
      |> assign(:count, initial_count)
      |> assign(:handle, handle)
      |> assign(:greeting, greeting)
      |> assign(:connected_at, connected_at)
      # Mutated by handle_event for the temporary-assigns probe
      |> assign(:notifications, [])

    {:ok, socket, temporary_assigns: [notifications: []]}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("inc", _params, socket) do
    {:noreply, update(socket, :count, &(&1 + 1))}
  end

  @impl true
  def handle_event("notify", _params, socket) do
    {:noreply,
     update(socket, :notifications, fn xs -> ["hello-" <> Integer.to_string(length(xs)) | xs] end)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="mount-vanilla">
      <p id="count">{@count}</p>
      <p id="handle">{@handle}</p>
      <p id="greeting">{@greeting}</p>
      <p id="connected">{to_string(not is_nil(@connected_at))}</p>
      <p id="notif-count">{length(@notifications)}</p>

      <ul id="notifs">
        <li :for={n <- @notifications}>{n}</li>
      </ul>

      <button id="inc" phx-click="inc">+1</button>
      <button id="notify" phx-click="notify">notify</button>
    </div>
    """
  end
end
