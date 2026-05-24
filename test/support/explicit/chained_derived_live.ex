defmodule Lavash.Test.Explicit.ChainedDerivedLive do
  @moduledoc """
  Counterpart to Lavash.Test.Magic.ChainedDerivedLive using
  Lavash.LiveView.Explicit. The reactive engine handles the chain;
  no manual recompute helpers needed.
  """
  use Lavash.LiveView.Explicit

  reactive do
    state :count, 1
    derive :doubled, rx(@count * 2)
    derive :quadrupled, rx(@doubled * 2)
    derive :octupled, rx(@quadrupled * 2)
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

  def handle_event("set_count", %{"value" => v}, socket) do
    {:noreply, put_state(socket, :count, String.to_integer(v))}
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
