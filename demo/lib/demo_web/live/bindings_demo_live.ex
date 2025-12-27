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

  # Chain of derives to test graph-based recomputation with topological sorting:
  # roast -> selected_count -> has_selection -> summary_text
  #                       \-> summary_text (also depends on selected_count directly)
  #
  # This tests:
  # 1. Transitive dependency discovery (changing roast affects all 3)
  # 2. Topological sorting (has_selection must compute before summary_text)

  # Level 1: depends on state
  derive :selected_count do
    argument :roast, state(:roast)
    optimistic true

    run fn %{roast: roast}, _ ->
      length(roast)
    end
  end

  # Level 2: depends on another derive
  derive :has_selection do
    argument :count, result(:selected_count)
    optimistic true

    run fn %{count: count}, _ ->
      count > 0
    end
  end

  # Level 3: depends on multiple derives (tests proper ordering)
  derive :summary_text do
    argument :count, result(:selected_count)
    argument :has_any, result(:has_selection)
    optimistic true

    run fn %{count: count, has_any: has_any}, _ ->
      if has_any do
        "#{count} roast#{if count == 1, do: "", else: "s"} selected"
      else
        "No roasts selected"
      end
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
        <h2 class="font-semibold mb-4">Roast Level Filter (Shadow DOM + morphdom)</h2>

        <.live_component
          module={Lavash.Components.TemplatedChipSet}
          id="roast-filter"
          bind={[selected: :roast]}
          selected={@roast}
          values={["light", "medium", "medium_dark", "dark"]}
          labels={%{"medium_dark" => "Med-Dark"}}
        />
      </div>

      <div class="bg-blue-50 p-6 rounded-lg">
        <h2 class="font-semibold mb-2">State from Parent Graph</h2>
        <div class="space-y-2">
          <p class="text-gray-600">
            Selected roasts: <code class="bg-gray-200 px-2 py-1 rounded">{inspect(@roast)}</code>
          </p>
          <p class="text-gray-600">
            Count (Level 1 derive): <code class="bg-gray-200 px-2 py-1 rounded">{@selected_count}</code>
          </p>
          <p class="text-gray-600">
            Has selection (Level 2 derive): <code class="bg-gray-200 px-2 py-1 rounded">{inspect(@has_selection)}</code>
          </p>
          <p class="text-gray-600">
            Summary (Level 3 derive): <code class="bg-gray-200 px-2 py-1 rounded">{@summary_text}</code>
          </p>
        </div>
        <p class="text-sm text-gray-500 mt-4">
          The ChipSet component binds its <code>selected</code> to the parent's <code>:roast</code> state.
          When you toggle chips, the parent state updates and the derive chain recomputes in order.
        </p>
      </div>
    </div>
    """
  end
end
