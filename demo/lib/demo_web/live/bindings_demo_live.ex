defmodule DemoWeb.BindingsDemoLive do
  @moduledoc """
  Demo page for Lavash.LiveComponent bindings.

  Shows how a component can bind to parent state and update it,
  with changes flowing through the reactive graph.
  """
  use Lavash.LiveView

  # State that the component will bind to
  # optimistic: true enables the wrapper hook that handles client-side updates
  state :roast, {:array, :string}, from: :url, default: [], optimistic: true

  # A derive that depends on the state - should update when ChipSet changes it
  derive :selected_count do
    argument :roast, state(:roast)

    run fn %{roast: roast}, _ ->
      length(roast)
    end
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-6">
      <div class="flex items-center justify-between mb-6">
        <div>
          <h1 class="text-3xl font-bold">Bindings Demo</h1>
          <p class="text-gray-500 mt-1">
            ChipSet component bound to parent :roast state
          </p>
        </div>
        <a href="/" class="text-indigo-600 hover:text-indigo-800">&larr; Home</a>
      </div>

      <div class="bg-gray-50 p-6 rounded-lg mb-6">
        <h2 class="font-semibold mb-4">Roast Level Filter</h2>

        <.live_component
          module={Lavash.Components.ChipSet}
          id="roast-filter"
          bind={[selected: :roast]}
          selected={@roast}
          values={["light", "medium", "medium_dark", "dark"]}
          labels={%{"medium_dark" => "Med-Dark"}}
        />
      </div>

      <div class="bg-blue-50 p-6 rounded-lg">
        <h2 class="font-semibold mb-2">State from Parent Graph</h2>
        <p class="text-gray-600">
          Selected roasts: <code class="bg-gray-200 px-2 py-1 rounded">{inspect(@roast)}</code>
        </p>
        <p class="text-gray-600 mt-2">
          Count (derived): <code class="bg-gray-200 px-2 py-1 rounded">{@selected_count}</code>
        </p>
        <p class="text-sm text-gray-500 mt-4">
          The ChipSet component binds its <code>selected</code> to the parent's <code>:roast</code> state.
          When you toggle chips, the parent state updates and derived values recompute.
        </p>
      </div>
    </div>
    """
  end
end
