defmodule DemoWeb.Builder.CounterLive do
  @moduledoc """
  Counter on the lavash core API — no DSL, no macros.

  The graph is built with `Reactive.new/state/derive/build`: every
  derive names its dependencies explicitly and computes with a plain
  function receiving a map of dep values. Events call
  `Reactive.put/3` + `Reactive.recompute/1` directly.

  Compare with `/reactive/counter` (defgraph) and
  `/reactive/explicit-counter` (`reactive do` block) — same page, the
  macros only compress what's written out here.
  """
  use DemoWeb, :live_view

  alias Lavash.Reactive

  defp graph do
    Reactive.graph(__MODULE__, fn ->
      Reactive.new()
      |> Reactive.state(:count, 0)
      |> Reactive.state(:step, 1)
      |> Reactive.derive(:product, [:count, :step], fn %{count: c, step: s} -> c * s end)
      |> Reactive.derive(:parity, [:count], fn %{count: c} ->
        if rem(c, 2) == 0, do: "even", else: "odd"
      end)
      |> Reactive.derive(:fact, [:count], &factorial_slow/1, async: true)
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

  def handle_info(msg, socket) do
    case Reactive.handle_async(socket, msg) do
      {:ok, socket} -> {:noreply, socket}
      :not_handled -> {:noreply, socket}
    end
  end

  # Async derive compute — receives the dep map like any other derive.
  def factorial_slow(%{count: count}) do
    Process.sleep(300)
    factorial(max(count, 0))
  end

  defp factorial(0), do: 1
  defp factorial(n) when n > 0 and n <= 170, do: n * factorial(n - 1)
  defp factorial(_), do: :infinity

  def render(assigns) do
    ~H"""
    <div class="max-w-md mx-auto mt-10 p-6 card bg-base-200">
      <h1 class="text-2xl font-bold text-center mb-2">Builder Counter</h1>
      <p class="text-sm text-base-content/60 text-center mb-6">
        Core API — explicit deps, plain functions, no macros
      </p>

      <div class="text-center mb-6">
        <div class="text-6xl font-mono font-bold text-primary mb-2">{@count}</div>
        <div class="badge badge-outline">{@parity}</div>
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
          <span class="font-mono font-bold text-lg">{@product}</span>
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
      </div>

      <div class="mt-6 text-center">
        <a href="/" class="link text-sm">&larr; All demos</a>
      </div>
    </div>
    """
  end
end
