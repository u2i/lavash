defmodule DemoWeb.LiveViewDemos.ExplicitCounterLive do
  @moduledoc """
  Counter built with `use Lavash.LiveView.Explicit` — the smallest
  non-DSL on-ramp.

  Compare with the two siblings:
  - `CounterLive` — `defgraph` + `Lavash.Reactive` runtime calls
  - `PlainCounterLive` — no Lavash Elixir at all, hand-coded JS hook

  `Explicit` provides `mount/3` (graph init), `handle_info/2` (async
  derive results), and `put_state/3` (put + recompute in one call);
  everything else is plain Phoenix LiveView.
  """
  use Lavash.LiveView.Explicit

  reactive do
    state :count, 0
    state :step, 1
    derive :product, rx(@count * @step)
    derive :parity, rx(if(rem(@count, 2) == 0, do: "even", else: "odd"))
    derive(:fib, rx(fib_slow(@count)), async: true)
  end

  @impl Phoenix.LiveView
  def handle_event("increment", _, socket) do
    {:noreply, put_state(socket, :count, &(&1 + 1))}
  end

  def handle_event("decrement", _, socket) do
    {:noreply, put_state(socket, :count, &(&1 - 1))}
  end

  def handle_event("set_step", %{"step" => step}, socket) do
    {:noreply, put_state(socket, :step, String.to_integer(step))}
  end

  def handle_event("reset", _, socket) do
    {:noreply, socket |> put_state(:count, 0) |> put_state(:step, 1)}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="max-w-md mx-auto mt-10 p-6 card bg-base-200">
      <h1 class="text-2xl font-bold text-center mb-2">Explicit Counter</h1>
      <p class="text-sm text-base-content/60 text-center mb-6">
        <code class="bg-base-300 px-1 rounded">use Lavash.LiveView.Explicit</code>
        — reactive graph, plain LiveView everything else
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
          <span class="text-base-content/70">fib({@count}) =</span>
          <span class="font-mono font-bold text-lg">
            <%= case @fib do %>
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
        <a href="/lv" class="link text-sm">&larr; LiveView demos</a>
      </div>
    </div>
    """
  end

  # Public: rx() compute functions are compiled outside the module's
  # private scope, so anything an rx calls must be public.
  def fib_slow(n) do
    Process.sleep(300)
    fib(max(n, 0))
  end

  defp fib(n) when n <= 1000 do
    {result, _} = Enum.reduce(1..max(n, 1), {0, 1}, fn _, {a, b} -> {b, a + b} end)
    if n == 0, do: 0, else: result
  end

  defp fib(_), do: :too_big
end
