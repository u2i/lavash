defmodule Lavash.Test.Explicit.CounterLive do
  @moduledoc """
  Counter using Lavash.LiveView.Explicit — the non-DSL on-ramp. State and
  derives are declared via `reactive do ... end`; `put_state/3` mutates
  + recomputes in one call. No Spark DSL, no ~L template, no JS hook;
  this is what "using lavash without the DSL" actually looks like.
  """
  use Lavash.LiveView.Explicit

  reactive do
    state :count, 0
    state :multiplier, 2
    derive :doubled, rx(@count * @multiplier)
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    count =
      case params do
        %{"count" => v} -> String.to_integer(v)
        _ -> 0
      end

    {:noreply, put_state(socket, :count, count)}
  end

  @impl Phoenix.LiveView
  def handle_event("increment", _, socket) do
    {:noreply, put_state(socket, :count, &(&1 + 1))}
  end

  def handle_event("decrement", _, socket) do
    {:noreply, put_state(socket, :count, &(&1 - 1))}
  end

  def handle_event("set_count", %{"value" => v}, socket) do
    {:noreply, put_state(socket, :count, String.to_integer(v))}
  end

  def handle_event("reset", _, socket) do
    {:noreply, put_state(socket, :count, 0)}
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
