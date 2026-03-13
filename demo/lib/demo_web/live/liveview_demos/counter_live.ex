defmodule DemoWeb.LiveViewDemos.CounterLive do
  @moduledoc """
  Counter demo using Lavash.Reactive in a plain LiveView — no DSL.

  Demonstrates:
  - Building a reactive graph with state and derived fields
  - `put/3` with value or function + `recompute/1`
  - Async derives with loading/error propagation
  - Graph caching via `Reactive.graph/2`
  """
  use DemoWeb, :live_view
  import Lavash.Rx

  alias Lavash.Reactive

  defp graph do
    Reactive.graph(__MODULE__, fn ->
      Reactive.new()
      |> Reactive.state(:count, 0)
      |> Reactive.state(:step, 1)
      |> Reactive.derive(:doubled, rx(@count * @step))
      |> Reactive.derive(:quad, rx(@doubled * 2))
      |> Reactive.derive(:fact, [:count], &factorial_async/1, async: true)
      |> Reactive.build()
    end)
  end

  def mount(_params, _session, socket) do
    {:ok, Reactive.init(socket, graph())}
  end

  def handle_event("increment", _, socket) do
    {:noreply, socket |> Reactive.put(:count, &(&1 + 1)) |> Reactive.recompute()}
  end

  def handle_event("decrement", _, socket) do
    {:noreply, socket |> Reactive.put(:count, &(&1 - 1)) |> Reactive.recompute()}
  end

  def handle_event("set_step", %{"step" => step}, socket) do
    {:noreply, socket |> Reactive.put(:step, String.to_integer(step)) |> Reactive.recompute()}
  end

  def handle_event("reset", _, socket) do
    socket =
      socket
      |> Reactive.put(:count, 0)
      |> Reactive.put(:step, 1)
      |> Reactive.recompute()

    {:noreply, socket}
  end

  def handle_event("set_100", _, socket) do
    {:noreply, socket |> Reactive.put(:count, 100) |> Reactive.recompute()}
  end

  def handle_info(msg, socket) do
    case Reactive.handle_async(socket, msg) do
      {:ok, socket} -> {:noreply, socket}
      :not_handled -> {:noreply, socket}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-md mx-auto mt-10 p-6 card bg-base-200">
      <h1 class="text-2xl font-bold text-center mb-6">Reactive Counter</h1>
      <p class="text-sm text-base-content/60 text-center mb-6">
        Plain LiveView using <code class="bg-base-300 px-1 rounded">Lavash.Reactive</code> — no DSL
      </p>

      <div class="text-center mb-6">
        <div class="text-6xl font-mono font-bold text-primary mb-2">{@count}</div>
      </div>

      <div class="flex justify-center gap-4 mb-6">
        <button phx-click="decrement" class="btn btn-error btn-lg text-xl font-bold">-</button>
        <button phx-click="increment" class="btn btn-success btn-lg text-xl font-bold">+</button>
      </div>

      <div class="space-y-4 border-t border-base-300 pt-4">
        <div class="flex items-center justify-between">
          <span class="text-base-content/70">Step:</span>
          <form phx-change="set_step">
            <input
              type="range"
              name="step"
              min="1"
              max="10"
              value={@step}
              class="range range-primary range-sm w-32"
            />
          </form>
          <span class="font-mono w-8 text-right">{@step}</span>
        </div>

        <div class="flex items-center justify-between">
          <span class="text-base-content/70">count x step =</span>
          <span class="font-mono font-bold text-lg">{@doubled}</span>
        </div>

        <div class="flex items-center justify-between">
          <span class="text-base-content/70">x 2 =</span>
          <span class="font-mono font-bold text-lg">{@quad}</span>
        </div>

        <div class="flex items-center justify-between">
          <span class="text-base-content/70">{@count}! =</span>
          <span class="font-mono font-bold text-lg">
            <%= case @fact do %>
              <% %Phoenix.LiveView.AsyncResult{loading: loading} when loading != nil -> %>
                <span class="text-base-content/40 animate-pulse">computing...</span>
              <% %Phoenix.LiveView.AsyncResult{ok?: true, result: value} -> %>
                {value}
              <% %Phoenix.LiveView.AsyncResult{failed: failed} when failed != nil -> %>
                <span class="text-error">error</span>
              <% _ -> %>
                ?
            <% end %>
          </span>
        </div>
      </div>

      <div class="mt-6 flex justify-center gap-2">
        <button phx-click="reset" class="btn btn-ghost btn-sm">Reset</button>
        <button phx-click="set_100" class="btn btn-ghost btn-sm">Set to 100</button>
      </div>

      <div class="mt-6 text-center">
        <a href={~p"/lv"} class="link text-sm">&larr; LiveView demos</a>
      </div>
    </div>
    """
  end

  defp factorial_async(%{count: n}) do
    Process.sleep(300)
    factorial(max(n, 0))
  end

  defp factorial(0), do: 1
  defp factorial(n) when n > 0 and n <= 170, do: n * factorial(n - 1)
  defp factorial(_), do: :infinity
end
