defmodule DemoWeb.TagEditorDemoLive do
  @moduledoc """
  Demo showing the TagEditor component with full client re-render model.

  This demonstrates:
  - Structural optimistic updates (adding/removing DOM nodes)
  - Tight scoping (no server content inside the optimistic region)
  - Clean separation between optimistic and server-rendered content
  """
  use Lavash.LiveView

  # Tags with optimistic updates
  state :tags, {:array, :string}, from: :url, default: ["elixir", "phoenix"], optimistic: true

  # Server-side derive for comparison
  derive :server_timestamp do
    argument :tags, state(:tags)

    run fn _args, _ ->
      DateTime.utc_now() |> DateTime.to_time() |> Time.truncate(:second) |> Time.to_string()
    end
  end

  # Optimistic derive
  derive :tag_summary do
    argument :tags, state(:tags)
    optimistic true

    run fn %{tags: tags}, _ ->
      case length(tags) do
        0 -> "No tags yet"
        1 -> "1 tag"
        n -> "#{n} tags"
      end
    end
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-6">
      <div class="flex items-center justify-between mb-6">
        <div>
          <h1 class="text-3xl font-bold">Tag Editor Demo</h1>
          <p class="text-gray-500 mt-1">
            Full client re-render with structural changes
          </p>
        </div>
        <a href="/demos/nested-optimistic" class="text-indigo-600 hover:text-indigo-800">
          &larr; Nested Optimistic Demo
        </a>
      </div>

      <div class="bg-blue-50 p-4 rounded-lg mb-6 text-sm">
        <p class="text-blue-800">
          <strong>How it works:</strong> Enable latency simulation (bottom right), then add/remove tags.
          Tags appear/disappear instantly (optimistic structural change), while server content
          updates after the round-trip.
        </p>
      </div>

      <div class="grid grid-cols-2 gap-6">
        <!-- Left: Optimistic region (self-contained, no server content inside) -->
        <div class="bg-gray-50 p-6 rounded-lg">
          <h2 class="font-semibold mb-4">Tag Editor (Optimistic)</h2>

          <.live_component
            module={Lavash.Components.TagEditor}
            id="demo-tags"
            bind={[tags: :tags]}
            tags={@tags}
            max_tags={8}
            placeholder="Type and press Enter..."
          />

          <p class="text-xs text-gray-400 mt-4">
            This component does full client re-render. Structure changes instantly.
          </p>
        </div>

        <!-- Right: Server content (completely separate) -->
        <div class="bg-white p-6 rounded-lg border">
          <h2 class="font-semibold mb-4">Server Content (Separate)</h2>

          <div class="space-y-4 text-sm">
            <div>
              <span class="text-gray-600">Server timestamp:</span>
              <span class="font-mono bg-gray-100 px-2 py-1 rounded ml-2">
                {@server_timestamp}
              </span>
            </div>

            <div>
              <span class="text-gray-600">Raw tags value:</span>
              <code class="bg-gray-100 px-2 py-1 rounded ml-2 text-xs">
                {inspect(@tags)}
              </code>
            </div>

            <div>
              <span class="text-gray-600">Tag summary (optimistic):</span>
              <span data-optimistic-display="tag_summary" class="ml-2 font-medium">
                {@tag_summary}
              </span>
            </div>
          </div>

          <p class="text-xs text-gray-400 mt-4">
            Server content lives <em>beside</em> the optimistic component, not inside it.
            No data-lavash-preserve needed.
          </p>
        </div>
      </div>

      <!-- Architecture explanation -->
      <div class="mt-8 bg-green-50 p-6 rounded-lg">
        <h2 class="font-semibold mb-3">Architecture: Clean Separation</h2>
        <div class="grid grid-cols-2 gap-4 text-sm">
          <div>
            <h3 class="font-medium text-green-800 mb-2">Optimistic Region</h3>
            <ul class="list-disc list-inside text-green-700 space-y-1">
              <li>Self-contained component</li>
              <li>No slots or server content inside</li>
              <li>Full client re-render on action</li>
              <li>Structural changes (add/remove nodes)</li>
            </ul>
          </div>
          <div>
            <h3 class="font-medium text-green-800 mb-2">Server Region</h3>
            <ul class="list-disc list-inside text-green-700 space-y-1">
              <li>Lives beside, not inside</li>
              <li>Normal LiveView patches</li>
              <li>Updates after server responds</li>
              <li>No special handling needed</li>
            </ul>
          </div>
        </div>
      </div>

      <!-- Contrast with nested approach -->
      <div class="mt-6 bg-yellow-50 p-6 rounded-lg">
        <h2 class="font-semibold mb-3">Contrast: Nested vs Separate</h2>
        <div class="text-sm text-yellow-800">
          <p class="mb-2">
            The <a href="/demos/nested-optimistic" class="underline">Nested Optimistic Demo</a>
            uses <code>data-lavash-preserve</code> to embed server content inside an optimistic
            component. This works but adds complexity.
          </p>
          <p>
            This demo shows the cleaner approach: keep optimistic regions small and self-contained,
            place server content beside them. No special preservation logic needed.
          </p>
        </div>
      </div>
    </div>
    """
  end
end
