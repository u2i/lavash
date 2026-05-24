defmodule Lavash.Test.Explicit.CounterLive do
  @moduledoc """
  Counter fixture using plain Phoenix.LiveView with no Lavash DSL, no rx(),
  no calculate, no actions block. Same observable contract as
  Lavash.Test.Magic.CounterLive.

  Counterpart to the magic counter — useful for verifying the integration
  tests don't accidentally couple to DSL internals.
  """
  use Phoenix.LiveView

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, assign(socket, multiplier: 2)}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    count =
      case params do
        %{"count" => v} -> String.to_integer(v)
        _ -> 0
      end

    {:noreply, socket |> assign(count: count) |> recompute_doubled()}
  end

  @impl Phoenix.LiveView
  def handle_event("increment", _params, socket) do
    {:noreply, socket |> update(:count, &(&1 + 1)) |> recompute_doubled()}
  end

  def handle_event("decrement", _params, socket) do
    {:noreply, socket |> update(:count, &(&1 - 1)) |> recompute_doubled()}
  end

  def handle_event("set_count", %{"value" => v}, socket) do
    {:noreply,
     socket
     |> assign(count: String.to_integer(v))
     |> recompute_doubled()}
  end

  def handle_event("reset", _, socket) do
    {:noreply, socket |> assign(count: 0) |> recompute_doubled()}
  end

  defp recompute_doubled(socket) do
    assign(socket, doubled: socket.assigns.count * socket.assigns.multiplier)
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div>
      <span id="count">{@count}</span>
      <span id="doubled">{@doubled}</span>
      <button id="inc" phx-click="increment">+</button>
      <button id="dec" phx-click="decrement">-</button>
      <button id="reset" phx-click="reset">Reset</button>
    </div>
    """
  end
end
