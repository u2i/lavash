defmodule Lavash.Parity.Lavash.HandleInfoLive do
  @moduledoc """
  Lavash DSL expression of the handle_info parity suite — paired
  with `Lavash.Parity.Vanilla.HandleInfoLive`.

  Uses the new `handle_info do on <pattern> do ... end end` block
  (introduced on this branch) for receive-side message dispatch.
  The body is plain Elixir; `assigns` is in scope; return the
  updated assigns and the runtime takes care of the recompute +
  project chain.

  The mount-level PubSub subscription still uses a custom
  `mount/3` — subscribing isn't yet declarative (will likely
  become a `connected do subscribe \"...\" end` block).
  """
  use Lavash.LiveView

  state :ticks, :integer, default: 0, optimistic: true
  state :last_msg, :string, default: nil, optimistic: true
  state :broadcasts, :integer, default: 0, optimistic: true

  actions do
    action :schedule_tick do
      effect fn _assigns -> Process.send_after(self(), :tick, 50) end
    end

    action :self_send do
      effect fn _assigns -> send(self(), {:custom_msg, "hello"}) end
    end

    action :broadcast do
      effect fn _assigns ->
        Phoenix.PubSub.broadcast(Lavash.PubSub, "parity:handle_info", :pinged)
      end
    end
  end

  handle_info do
    on :tick do
      assign(assigns, :ticks, assigns.ticks + 1)
    end

    on {:custom_msg, msg}, [:msg] do
      assign(assigns, :last_msg, msg)
    end

    on :pinged do
      assign(assigns, :broadcasts, assigns.broadcasts + 1)
    end
  end

  template do
    ~H"""
    <div id="handle-info-lavash">
      <p id="ticks">{@ticks}</p>
      <p id="last-msg">{@last_msg || "(none)"}</p>
      <p id="broadcasts">{@broadcasts}</p>

      <button id="schedule" phx-click="schedule_tick">schedule</button>
      <button id="self-send" phx-click="self_send">self send</button>
      <button id="broadcast" phx-click="broadcast">broadcast</button>
    </div>
    """
  end

  # Subscribe at mount. `connected do ... end` will eventually
  # absorb this; for now, the custom mount is the escape hatch.
  @impl Phoenix.LiveView
  def mount(params, session, socket) do
    {:ok, socket} = Lavash.LiveView.Runtime.mount(__MODULE__, params, session, socket)

    if Phoenix.LiveView.connected?(socket) do
      Phoenix.PubSub.subscribe(Lavash.PubSub, "parity:handle_info")
    end

    {:ok, socket}
  end
end
