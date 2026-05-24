defmodule Lavash.Test.Explicit.AsyncChainLive do
  @moduledoc """
  Counterpart to Lavash.Test.Magic.AsyncChainLive using
  Lavash.LiveView.Explicit. Demonstrates async derives without the DSL —
  same `Lavash.Reactive.handle_async/2` dispatch the magic path uses,
  wired up by the `use` macro.
  """
  use Lavash.LiveView.Explicit

  reactive do
    state :count, 1
    derive(:doubled, rx(slow_double(@count)), async: true)
    derive :quadrupled, rx(@doubled * 2)
  end

  def slow_double(c) do
    Process.sleep(50)
    c * 2
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    count =
      case params do
        %{"count" => v} -> String.to_integer(v)
        _ -> 1
      end

    {:noreply, put_state(socket, :count, count)}
  end

  @impl Phoenix.LiveView
  def handle_event("increment", _, socket) do
    {:noreply, put_state(socket, :count, &(&1 + 1))}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div>
      <span id="count">{@count}</span>
      <span id="doubled">
        <%= case @doubled do %>
          <% %Phoenix.LiveView.AsyncResult{ok?: true, result: val} -> %>{val}
          <% _ -> %>loading
        <% end %>
      </span>
      <span id="quadrupled">
        <%= case @quadrupled do %>
          <% %Phoenix.LiveView.AsyncResult{ok?: true, result: val} -> %>{val}
          <% _ -> %>loading
        <% end %>
      </span>
      <button id="inc" phx-click="increment">+</button>
    </div>
    """
  end
end
