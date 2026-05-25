defmodule Lavash.Parity.Lavash.MountLive do
  @moduledoc """
  Lavash DSL expression of the mount/3 parity suite — paired with
  `Lavash.Parity.Vanilla.MountLive`.

  Coverage state vs vanilla:

  * `:count` from URL param — `state :count, from: :url`. ✓
  * `:handle` from session — `state :handle, from: :session`. ✓
    (Hydrated by the runtime via the Plug session at mount; no
    custom `mount/3` required.)
  * `:notifications` literal list default — `state :notifications`. ✓
  * `:greeting` derived from another field — `calculate :greeting`. ✓
  * `:connected_at` requires `connected?(socket)` branching at mount —
    not yet expressible declaratively. Hydrated via the custom
    `mount/3` escape hatch (defoverridable).
  * `temporary_assigns` — no DSL surface; the custom mount returns
    `{:ok, socket, temporary_assigns: [...]}` directly.
  """
  use Lavash.LiveView

  state :count, :integer, from: :url, default: 0, optimistic: true
  state :handle, :string, from: :session, default: "guest", optimistic: true
  state :notifications, {:array, :string}, default: [], optimistic: true

  calculate :greeting, rx("Hello, " <> @handle)
  # Boolean projection of :connected_at for parity with vanilla's
  # `to_string(not is_nil(@connected_at))` render.
  calculate :connected, rx(not is_nil(@connected_at))

  # See moduledoc — these can't (yet) be declared as state with a
  # `from:` shape, so they're stored as state with no `from:` and
  # populated by the custom mount/3 below.
  state :connected_at, :integer, default: nil

  actions do
    action :inc do
      set :count, rx(@count + 1)
    end

    action :notify do
      # Lavash's `set` evaluates the rx against current state; a
      # length-based item works fine here.
      set :notifications,
          rx(["hello-" <> Integer.to_string(length(@notifications)) | @notifications])
    end
  end

  template do
    ~H"""
    <div id="mount-lavash">
      <p id="count">{@count}</p>
      <p id="handle">{@handle}</p>
      <p id="greeting">{@greeting}</p>
      <p id="connected">{to_string(@connected)}</p>
      <p id="notif-count">{length(@notifications)}</p>

      <ul id="notifs">
        <li :for={n <- @notifications}>{n}</li>
      </ul>

      <button id="inc" phx-click="inc">+1</button>
      <button id="notify" phx-click="notify">notify</button>
    </div>
    """
  end

  # Escape hatch: still needed for `connected?(socket)` branching and
  # for the `temporary_assigns:` return-tuple. `:handle` no longer
  # needs the escape hatch — `from: :session` covers it.
  @impl Phoenix.LiveView
  def mount(params, session, socket) do
    {:ok, socket} = Lavash.LiveView.Runtime.mount(__MODULE__, params, session, socket)

    connected_at =
      if Phoenix.LiveView.connected?(socket),
        do: System.system_time(:second),
        else: nil

    socket = Lavash.Socket.put_state(socket, :connected_at, connected_at)

    {:ok, socket, temporary_assigns: [notifications: []]}
  end
end
