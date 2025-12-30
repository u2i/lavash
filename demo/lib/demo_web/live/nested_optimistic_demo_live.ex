defmodule DemoWeb.NestedOptimisticDemoLive do
  @moduledoc """
  Demo showing optimistic component with non-optimistic content nested inside.

  This demonstrates the hybrid rendering approach where:
  - The outer ChipSet is optimistic (instant UI feedback via client-side render)
  - The inner content is server-rendered normally (no optimistic updates)

  When you click a chip:
  1. pendingCount++ → client renders the chip change instantly
  2. Server patch arrives but is SKIPPED (onBeforeElUpdated returns false)
  3. Server responds to pushEventTo → pendingCount--
  4. Next server patch is ACCEPTED (pendingCount === 0)

  The key: non-optimistic content inside still gets server patches when pendingCount === 0.
  """
  use Lavash.LiveView

  # Optimistic state - the ChipSet will update instantly
  state :roast, {:array, :string}, from: :url, default: [], optimistic: true

  # Server-side derive that generates a new timestamp each render
  # This is NOT optimistic, so it only updates when server renders
  derive :server_timestamp do
    argument :roast, state(:roast)

    run fn _args, _ ->
      DateTime.utc_now() |> DateTime.to_time() |> Time.truncate(:second) |> Time.to_string()
    end
  end

  # Also optimistic derive for comparison
  derive :selection_summary do
    argument :roast, state(:roast)
    optimistic true

    run fn %{roast: roast}, _ ->
      case length(roast) do
        0 -> "No roasts selected"
        1 -> "1 roast selected"
        n -> "#{n} roasts selected"
      end
    end
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-6">
      <div class="flex items-center justify-between mb-6">
        <div>
          <h1 class="text-3xl font-bold">Nested Optimistic Demo</h1>
          <p class="text-gray-500 mt-1">
            Optimistic outer component + non-optimistic inner content
          </p>
        </div>
        <a href="/demos/bindings" class="text-indigo-600 hover:text-indigo-800">&larr; Bindings Demo</a>
      </div>

      <div class="bg-blue-50 p-4 rounded-lg mb-6 text-sm">
        <p class="text-blue-800">
          <strong>How it works:</strong> Enable latency simulation (bottom right), then click chips rapidly.
          The chips update instantly (optimistic), but the "Server render count" only updates
          after the server responds.
        </p>
      </div>

      <div class="bg-gray-50 p-6 rounded-lg mb-6">
        <h2 class="font-semibold mb-4">ChipSet with Preserved Slot</h2>

        <.live_component
          module={Lavash.Components.ChipSetWithSlot}
          id="roast-filter"
          bind={[selected: :roast]}
          selected={@roast}
          __lavash_parent_version__={@__lavash_parent_version__}
          values={["light", "medium", "medium_dark", "dark"]}
          labels={%{"medium_dark" => "Med-Dark"}}
        >
          <:footer>
            <%!-- This content is INSIDE the optimistic component but preserved by morphdom --%>
            <div class="p-4 bg-white rounded border">
              <h3 class="font-medium text-gray-700 mb-2">Preserved Content (Server Rendered)</h3>

              <div class="space-y-2 text-sm">
                <p>
                  Server timestamp:
                  <span class="font-mono bg-gray-100 px-2 py-1 rounded">{@server_timestamp}</span>
                  <span class="text-gray-500 ml-2">(updates when server responds)</span>
                </p>

                <p>
                  Raw roast value:
                  <code class="bg-gray-100 px-2 py-1 rounded">{inspect(@roast)}</code>
                </p>
              </div>

              <p class="text-xs text-gray-400 mt-3">
                This content is inside the ChipSet but marked with data-lavash-preserve.
                Morphdom skips it during client renders, only server patches update it.
              </p>
            </div>
          </:footer>
        </.live_component>
      </div>

      <div class="bg-green-50 p-6 rounded-lg">
        <h2 class="font-semibold mb-2">Optimistic Derive (Client Computed)</h2>
        <p class="text-lg">
          <span data-optimistic-display="selection_summary">{@selection_summary}</span>
        </p>
        <p class="text-xs text-gray-500 mt-2">
          This updates instantly because it's marked <code>optimistic: true</code>
        </p>
      </div>
    </div>
    """
  end
end
