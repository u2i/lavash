defmodule Lavash.Parity.Lavash.HandleInfoLive do
  @moduledoc """
  Lavash DSL expression of the handle_info parity suite — paired
  with `Lavash.Parity.Vanilla.HandleInfoLive`.

  Coverage vs vanilla:

    * `:ticks`, `:last_msg`, `:broadcasts` — plain `state` fields.
    * The action that schedules a tick, sends a self-message, and
      broadcasts via PubSub all live in `effect fn` bodies — they
      perform side effects but return the socket unchanged.
    * The receive side (handle_info clauses for :tick, :custom_msg,
      :pinged) requires a custom `handle_info/2` override. The DSL
      doesn't have a `handle_info do ... end` block today; this is
      a documented gap.

  When the gap closes, the shape will likely be:

      handle_info do
        on :tick do
          set :ticks, rx(@ticks + 1)
        end

        on {:custom_msg, msg}, [:msg] do
          set :last_msg, rx(@msg)
        end
      end

  Until then, the escape hatch (this file) is how parity is
  achieved.
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

  # Escape hatch: custom mount to subscribe + custom handle_info to
  # dispatch. Both are documented gaps the DSL doesn't cover yet.
  @impl Phoenix.LiveView
  def mount(params, session, socket) do
    {:ok, socket} = Lavash.LiveView.Runtime.mount(__MODULE__, params, session, socket)

    if Phoenix.LiveView.connected?(socket) do
      Phoenix.PubSub.subscribe(Lavash.PubSub, "parity:handle_info")
    end

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_info(:tick, socket) do
    {:noreply, bump_state(socket, :ticks, socket.assigns.ticks + 1)}
  end

  def handle_info({:custom_msg, msg}, socket) do
    {:noreply, bump_state(socket, :last_msg, msg)}
  end

  def handle_info(:pinged, socket) do
    {:noreply, bump_state(socket, :broadcasts, socket.assigns.broadcasts + 1)}
  end

  # Fall through to the runtime's handle_info for anything we
  # don't pattern-match (e.g. lavash internal PubSub messages).
  def handle_info(msg, socket) do
    Lavash.LiveView.Runtime.handle_info(__MODULE__, msg, socket)
  end

  # Helper: put_state + recompute + project, mirroring what the
  # action runtime does at the end of handle_event. This is the
  # same boilerplate you'd write today for any custom handle_info.
  # The future `handle_info do on :foo do set ... end end` DSL
  # block would absorb this.
  defp bump_state(socket, field, value) do
    socket
    |> Lavash.Socket.put_state(field, value)
    |> Lavash.Reactive.recompute()
    |> Lavash.Assigns.project(__MODULE__)
  end
end
