defmodule DemoWeb.CounterLive do
  use Lavash.LiveView

  state :count, :integer, from: :url, default: 0
  state :multiplier, :integer, from: :ephemeral, default: 2

  derive :doubled do
    argument :count, state(:count)
    argument :multiplier, state(:multiplier)
    run fn %{count: c, multiplier: m}, _ ->
      c * m
    end
  end

  derive :fact do
    async true
    argument :count, state(:count)
    run fn %{count: c}, _ ->
      # Simulate slow computation
      Process.sleep(500)
      factorial(max(c, 0))
    end
  end

  actions do
    action :increment do
      update :count, &(&1 + 1)
    end

    action :decrement do
      update :count, &(&1 - 1)
    end

    action :set_count, [:amount] do
      set :count, & String.to_integer(&1.params.amount)
    end

    action :set_multiplier, [:value] do
      set :multiplier, & String.to_integer(&1.params.value)
    end

    action :reset do
      set :count, 0
      set :multiplier, 2
    end
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-md mx-auto mt-10 p-6 bg-white rounded-lg shadow-lg">
      <h1 class="text-2xl font-bold text-center mb-6">Lavash Counter Demo</h1>

      <div class="text-center mb-6">
        <div class="text-6xl font-mono font-bold text-indigo-600 mb-2">
          {@count}
        </div>
        <p class="text-gray-500">
          Count is stored in URL - try refreshing or using back/forward
        </p>
      </div>

      <div class="flex justify-center gap-4 mb-6">
        <button
          phx-click="decrement"
          class="px-6 py-3 bg-red-500 text-white rounded-lg hover:bg-red-600 text-xl font-bold"
        >
          -
        </button>
        <button
          phx-click="increment"
          class="px-6 py-3 bg-green-500 text-white rounded-lg hover:bg-green-600 text-xl font-bold"
        >
          +
        </button>
      </div>

      <div class="space-y-4 border-t pt-4">
        <div class="flex items-center justify-between">
          <span class="text-gray-600">Multiplier:</span>
          <form phx-change="set_multiplier">
            <input
              type="range"
              name="value"
              min="1"
              max="10"
              value={@multiplier}
              class="w-32"
            />
          </form>
          <span class="font-mono w-8 text-right">{@multiplier}</span>
        </div>

        <div class="flex items-center justify-between">
          <span class="text-gray-600">Count x {@multiplier} =</span>
          <span class="font-mono font-bold text-lg">{@doubled}</span>
        </div>

        <div class="flex items-center justify-between">
          <span class="text-gray-600">{@count}! =</span>
          <span class="font-mono font-bold text-lg">
            <%= case @fact do %>
              <% :loading -> %>
                <span class="text-gray-400 animate-pulse">computing...</span>
              <% {:ok, value} -> %>
                {value}
              <% _ -> %>
                ?
            <% end %>
          </span>
        </div>
      </div>

      <div class="mt-6 flex justify-center gap-2">
        <button
          phx-click="reset"
          class="px-4 py-2 bg-gray-200 text-gray-700 rounded hover:bg-gray-300"
        >
          Reset
        </button>
        <button
          phx-click="set_count"
          phx-value-amount="100"
          class="px-4 py-2 bg-indigo-100 text-indigo-700 rounded hover:bg-indigo-200"
        >
          Set to 100
        </button>
      </div>

      <div class="mt-6 text-xs text-gray-400 text-center">
        <p>Current URL: <code class="bg-gray-100 px-1 rounded">{@count != 0 && "?count=#{@count}" || "/"}</code></p>
      </div>

      <div class="mt-6 text-center">
        <a href="/products" class="text-indigo-600 hover:text-indigo-800">
          View Products Demo &rarr;
        </a>
      </div>
    </div>
    """
  end

  defp factorial(0), do: 1
  defp factorial(n) when n > 0, do: n * factorial(n - 1)
end
