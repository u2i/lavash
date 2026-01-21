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

  # Server-side calculation for comparison (uses @tags to trigger recomputation)
  calculate :server_timestamp, rx(get_timestamp(@tags)), optimistic: false

  # Optimistic calculation - transpiles to both Elixir and JavaScript
  calculate :tag_count, rx(length(@tags))

  calculate :tag_summary,
            rx(
              if(length(@tags) == 0,
                do: "No tags yet",
                else: if(length(@tags) == 1, do: "1 tag", else: "#{length(@tags)} tags")
              )
            )

  calculate :tags_display, rx(Enum.join(@tags, ", "))

  render fn assigns ->
    ~L"""
    <div class="max-w-4xl mx-auto p-6">
      <div class="flex items-center justify-between mb-6">
        <div>
          <h1 class="text-3xl font-bold">Tag Editor Demo</h1>
          <p class="text-gray-500 mt-1">
            Full client re-render with structural changes
          </p>
        </div>
        <a href="/" class="text-indigo-600 hover:text-indigo-800">&larr; Demos</a>
      </div>

      <div class="bg-blue-50 p-4 rounded-lg mb-6 text-sm">
        <p class="text-blue-800">
          <strong>How it works:</strong> Enable latency simulation (bottom right), then add/remove tags.
          Tags appear/disappear instantly (optimistic structural change), while server content
          updates after the round-trip.
        </p>
      </div>

      <div class="grid grid-cols-3 gap-6">
        <!-- Left: Optimistic region (self-contained, no server content inside) -->
        <div class="bg-gray-50 p-6 rounded-lg">
          <h2 class="font-semibold mb-4">Tag Editor A</h2>

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

        <!-- Middle: Second tag editor bound to the same state -->
        <div class="bg-gray-50 p-6 rounded-lg">
          <h2 class="font-semibold mb-4">Tag Editor B (Sibling)</h2>

          <.live_component
            module={Lavash.Components.TagEditor}
            id="demo-tags-sibling"
            bind={[tags: :tags]}
            tags={@tags}
            max_tags={8}
            placeholder="Add tags here too..."
          />

          <p class="text-xs text-gray-400 mt-4">
            Both editors bind to the same parent <code>tags</code> state.
            Changes in one appear instantly in the other.
          </p>
        </div>

        <!-- Right: Server content (completely separate) -->
        <div class="bg-white p-6 rounded-lg border">
          <h2 class="font-semibold mb-4">Server Content</h2>

          <div class="space-y-4 text-sm">
            <div>
              <span class="text-gray-600">Server timestamp:</span>
              <span class="font-mono bg-gray-100 px-2 py-1 rounded ml-2">
                {@server_timestamp}
              </span>
            </div>

            <div>
              <span class="text-gray-600">Tags (optimistic):</span>
              <span data-lavash-display="tags_display" class="ml-2 font-medium">
                {@tags_display}
              </span>
            </div>

            <div>
              <span class="text-gray-600">Tag summary (optimistic):</span>
              <span data-lavash-display="tag_summary" class="ml-2 font-medium">
                {@tag_summary}
              </span>
            </div>
          </div>

          <p class="text-xs text-gray-400 mt-4">
            Server content lives <em>beside</em> the optimistic components.
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
        <h2 class="font-semibold mb-3">Best Practice: Keep Optimistic Regions Small</h2>
        <div class="text-sm text-yellow-800">
          <p>
            Keep optimistic regions small and self-contained,
            place server content beside them. No special preservation logic needed.
          </p>
        </div>
      </div>
    </div>
    """
  end

  # Helper for server timestamp - takes tags as arg to trigger recomputation when tags change
  def get_timestamp(_tags) do
    DateTime.utc_now() |> DateTime.to_time() |> Time.truncate(:second) |> Time.to_string()
  end
end
