defmodule DemoWeb.BindingsDemoLive do
  @moduledoc """
  Demo page for Lavash.ClientComponent bindings.

  Shows how a component can bind to parent state and update it,
  with changes flowing through the reactive graph.
  """
  use Lavash.LiveView

  # State that the component will bind to
  # optimistic: true enables the wrapper hook that handles client-side updates
  state :roast, {:array, :string}, from: :url, default: [], optimistic: true

  # Chain of calculations to test graph-based recomputation with topological sorting:
  # roast -> selected_count -> has_selection -> summary_text
  #                       \-> summary_text (also depends on selected_count directly)
  #
  # This tests:
  # 1. Transitive dependency discovery (changing roast affects all 3)
  # 2. Topological sorting (has_selection must compute before summary_text)

  # Level 1: depends on state
  calculate :selected_count, rx(length(@roast))

  # Level 2: depends on another calculation
  calculate :has_selection, rx(@selected_count > 0)

  # Level 3: depends on multiple calculations (tests proper ordering)
  calculate :summary_text,
            rx(
              if @has_selection do
                "#{@selected_count} roast#{if @selected_count == 1, do: "", else: "s"} selected"
              else
                "No roasts selected"
              end
            )

  render fn assigns ->
    ~H"""
    <div class="max-w-4xl mx-auto p-6">
      <div class="flex items-center justify-between mb-6">
        <div>
          <h1 class="text-3xl font-bold">Bindings Demo</h1>
          <p class="text-gray-500 mt-1">
            ChipSet component bound to parent :roast state
          </p>
        </div>
        <a href="/" class="text-indigo-600 hover:text-indigo-800">&larr; Demos</a>
      </div>

      <div class="bg-gray-50 p-6 rounded-lg mb-6">
        <h2 class="font-semibold mb-4">Roast Level Filter (Shadow DOM + morphdom)</h2>

        <.live_component
          module={Lavash.Components.ChipSet}
          id="roast-filter"
          bind={[selected: :roast]}
          selected={@roast}
          __lavash_parent_version__={@__lavash_parent_version__}
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
            Count (Level 1 calc): <code class="bg-gray-200 px-2 py-1 rounded">{@selected_count}</code>
          </p>
          <p class="text-gray-600">
            Has selection (Level 2 calc): <code class="bg-gray-200 px-2 py-1 rounded">{inspect(@has_selection)}</code>
          </p>
          <p class="text-gray-600">
            Summary (Level 3 calc): <code class="bg-gray-200 px-2 py-1 rounded">{@summary_text}</code>
          </p>
        </div>
        <p class="text-sm text-gray-500 mt-4">
          The ChipSet component binds its <code>selected</code> to the parent's <code>:roast</code> state.
          When you toggle chips, the parent state updates and the calculation chain recomputes in order.
        </p>
      </div>
    </div>
    """
  end
end
