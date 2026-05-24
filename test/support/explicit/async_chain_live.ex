defmodule Lavash.Test.Explicit.AsyncChainLive do
  @moduledoc """
  Plain Phoenix.LiveView counterpart to Lavash.Test.Magic.AsyncChainLive.
  Uses assign_async/3 for the slow_double step instead of
  `calculate :doubled, rx(...), async: true`.
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

  defp recompute(socket) do
    count = socket.assigns.count

    socket
    |> Phoenix.LiveView.assign_async(:doubled, fn ->
      {:ok, %{doubled: slow_double(count)}}
    end)
    |> assign(quadrupled_pending: count)
  end

  def slow_double(c) do
    Process.sleep(50)
    c * 2
  end

  @impl Phoenix.LiveView
  def handle_async(:doubled, {:ok, %{doubled: val}}, socket) do
    {:noreply, assign(socket, doubled_value: val, quadrupled: val * 2)}
  end

  def handle_async(_, _, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div>
      <span id="count">{@count}</span>
      <span id="doubled">{assigns[:doubled_value]}</span>
      <span id="quadrupled">{assigns[:quadrupled]}</span>
      <button id="inc" phx-click="increment">+</button>
    </div>
    """
  end
end
