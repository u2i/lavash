defmodule DemoWeb.LiveViewDemos.PlainCounterLive do
  @moduledoc """
  Counter built with plain LiveView + hand-coded JS hook.

  No Lavash DSL, no rx, no auto-generated JS. Uses the raw client
  primitives (SyncedVarStore, syncStateToUrl) to validate the API design.

  Feature parity with DemoWeb.CounterLive (DSL version):
  - count: URL-backed integer state
  - multiplier: ephemeral integer state
  - doubled: synchronous derive (count * multiplier)
  - fact: async derive (server computes slow factorial, client computes instant)
  - Actions: increment, decrement, set_count (with param), set_multiplier, reset
  """
  use DemoWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       count: 0,
       multiplier: 2,
       doubled: 0,
       fact: nil,
       fact_loading: false,
       page_title: "Plain Counter"
     )}
  end

  def handle_params(params, _uri, socket) do
    count = parse_int(params["count"], 0)
    socket = recompute(socket, count, socket.assigns.multiplier)
    {:noreply, socket}
  end

  def handle_event("increment", _, socket) do
    {:noreply, update_count(socket, socket.assigns.count + 1)}
  end

  def handle_event("decrement", _, socket) do
    {:noreply, update_count(socket, socket.assigns.count - 1)}
  end

  def handle_event("set_count", %{"value" => value}, socket) do
    {:noreply, update_count(socket, parse_int(value, 0))}
  end

  def handle_event("set_multiplier", %{"value" => value}, socket) do
    multiplier = parse_int(value, socket.assigns.multiplier)
    {:noreply, recompute(socket, socket.assigns.count, multiplier)}
  end

  def handle_event("reset", _, socket) do
    {:noreply, recompute(socket, 0, 2)}
  end

  # Async factorial result
  def handle_info({ref, result}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    if ref == socket.assigns[:_fact_ref] do
      {:noreply, assign(socket, fact: result, fact_loading: false, _fact_ref: nil)}
    else
      # Stale result from previous computation — ignore
      {:noreply, socket}
    end
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket) do
    {:noreply, socket}
  end

  defp update_count(socket, count) do
    recompute(socket, count, socket.assigns.multiplier)
  end

  defp recompute(socket, count, multiplier) do
    # Cancel previous async if still running
    if ref = socket.assigns[:_fact_ref] do
      Process.demonitor(ref, [:flush])
    end

    # Start async factorial
    task = Task.async(fn -> factorial_slow(max(count, 0)) end)

    assign(socket,
      count: count,
      multiplier: multiplier,
      doubled: count * multiplier,
      fact_loading: true,
      _fact_ref: task.ref
    )
  end

  defp factorial_slow(n) do
    Process.sleep(500)
    factorial(n)
  end

  defp factorial(0), do: 1
  defp factorial(n) when n > 0 and n <= 170, do: n * factorial(n - 1)
  defp factorial(_), do: :infinity

  defp parse_int(nil, default), do: default
  defp parse_int(val, default) when is_integer(val), do: val

  defp parse_int(str, default) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> default
    end
  end

  def render(assigns) do
    ~H"""
    <div
      id="plain-counter"
      phx-hook="PlainCounter"
      data-state={Jason.encode!(%{
        count: @count,
        multiplier: @multiplier,
        doubled: @doubled,
        fact: @fact,
        fact_loading: @fact_loading
      })}
      data-url-fields={Jason.encode!(["count"])}
      class="max-w-md mx-auto mt-10 p-6 card bg-base-200"
    >
      <h1 class="text-2xl font-bold text-center mb-2">Plain Counter</h1>
      <p class="text-sm text-base-content/60 text-center mb-6">
        Plain LiveView + hand-coded JS hook — no Lavash DSL
      </p>

      <div class="text-center mb-6">
        <div data-display="count" class="text-6xl font-mono font-bold text-primary mb-2">
          {@count}
        </div>
        <p class="text-base-content/50 text-sm">
          Count is stored in URL — try refreshing or using back/forward
        </p>
      </div>

      <div class="flex justify-center gap-4 mb-6">
        <button data-action="decrement" class="btn btn-error btn-lg text-xl font-bold">-</button>
        <button data-action="increment" class="btn btn-success btn-lg text-xl font-bold">+</button>
      </div>

      <div class="space-y-4 border-t border-base-300 pt-4">
        <div class="flex items-center justify-between">
          <span class="text-base-content/70">Multiplier:</span>
          <form phx-change="set_multiplier">
            <input
              type="range"
              name="value"
              min="1"
              max="10"
              value={@multiplier}
              data-bind="multiplier"
              class="range range-primary range-sm w-32"
            />
          </form>
          <span data-display="multiplier" class="font-mono w-8 text-right">{@multiplier}</span>
        </div>

        <div class="flex items-center justify-between">
          <span class="text-base-content/70">
            <span data-display="count">{@count}</span>
            x <span data-display="multiplier">{@multiplier}</span> =
          </span>
          <span data-display="doubled" class="font-mono font-bold text-lg">{@doubled}</span>
        </div>

        <div class="flex items-center justify-between">
          <span class="text-base-content/70">
            <span data-display="count">{@count}</span>! =
          </span>
          <span data-display="fact" class="font-mono font-bold text-lg">
            <%= if @fact_loading do %>
              <span class="text-base-content/40 animate-pulse">computing...</span>
            <% else %>
              {@fact || "?"}
            <% end %>
          </span>
        </div>
      </div>

      <div class="mt-6 flex justify-center gap-2">
        <button data-action="reset" class="btn btn-ghost btn-sm">Reset</button>
        <button data-action="set_count" data-value="100" class="btn btn-ghost btn-sm">
          Set to 100
        </button>
      </div>

      <div class="mt-6 text-xs text-base-content/40 text-center">
        <p>
          Current URL:
          <code class="bg-base-300 px-1 rounded">{(@count != 0 && "?count=#{@count}") || "/"}</code>
        </p>
      </div>

      <div class="mt-6 text-center">
        <a href={~p"/lv"} class="link text-sm">&larr; LiveView demos</a>
      </div>
    </div>
    """
  end
end
