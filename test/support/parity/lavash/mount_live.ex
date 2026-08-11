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
    `mount do when_connected do ... end end`. ✓
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
  calculate :connected, rx(not is_nil(@connected_at)), optimistic: false

  # Populated by the `mount do when_connected ... end` block below.
  # No `from:` — `:connected_at` is a regular ephemeral state field
  # whose value is set imperatively at mount time when the socket is
  # actually connected (i.e. on the websocket-mount pass, not the
  # initial HTTP render).
  state :connected_at, :integer, default: nil

  mount do
    when_connected do
      set :connected_at, System.system_time(:second)
    end
  end

  actions do
    action :inc do
      set :count, rx(@count + 1)
    end

    action :notify do
      # Cons + string interpolation isn't transpilable, and this parity
      # fixture is about mount/session semantics, not optimism — use
      # the server-only function form (issue #46 makes untranspilable
      # rx in an optimistic action a compile error).
      set :notifications, fn %{state: state} ->
        ["hello-#{length(state.notifications)}" | state.notifications]
      end
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

  # Escape hatch: still needed for the `temporary_assigns:` return-tuple.
  # `:connected_at` is now handled by `mount do when_connected ... end`
  # above; `:handle` by `from: :session`.
  @impl Phoenix.LiveView
  def mount(params, session, socket) do
    {:ok, socket} = Lavash.LiveView.Runtime.mount(__MODULE__, params, session, socket)
    {:ok, socket, temporary_assigns: [notifications: []]}
  end
end
