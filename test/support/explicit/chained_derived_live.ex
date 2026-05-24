defmodule Lavash.Test.Explicit.ChainedDerivedLive do
  @moduledoc """
  Plain Phoenix.LiveView counterpart to Lavash.Test.Magic.ChainedDerivedLive.
  Same chain: count → doubled → quadrupled → octupled. No DSL — derived
  values are recomputed in a private helper that fires after every state
  mutation.
  """
  use Phoenix.LiveView

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    count =
      case params do
        %{"count" => v} -> String.to_integer(v)
        _ -> 1
      end

    {:noreply, recompute(assign(socket, count: count))}
  end

  @impl Phoenix.LiveView
  def handle_event("increment", _, socket) do
    {:noreply, recompute(update(socket, :count, &(&1 + 1)))}
  end

  def handle_event("set_count", %{"value" => v}, socket) do
    {:noreply, recompute(assign(socket, count: String.to_integer(v)))}
  end

  defp recompute(socket) do
    count = socket.assigns.count
    doubled = count * 2
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
      <span id="count">{@count}</span>
      <span id="doubled">{@doubled}</span>
      <span id="quadrupled">{@quadrupled}</span>
      <span id="octupled">{@octupled}</span>
      <button id="inc" phx-click="increment">+</button>
    </div>
    """
  end
end
