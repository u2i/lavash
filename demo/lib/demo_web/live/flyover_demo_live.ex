defmodule DemoWeb.FlyoverDemoLive do
  @moduledoc """
  Demo page for the Flyover (slideover) component.

  Shows how to use the Lavash.Overlay.Flyover.Dsl extension to create
  sliding panels that animate in from the screen edges.
  """
  use Lavash.LiveView
  import Lavash.LiveView.Helpers

  # Track which direction demo is active
  state :active_direction, :atom, from: :ephemeral, default: nil, optimistic: true

  defp usage_example do
    """
    defmodule MyApp.NavFlyover do
      use Lavash.Component, extensions: [Lavash.Overlay.Flyover.Dsl]

      flyover do
        open_field :open
        slide_from :left   # or :right, :top, :bottom
        width :sm          # :sm, :md, :lg, :xl, :full
      end

      render fn assigns ->
        ~H&quot;&quot;&quot;
        &lt;div class="h-full p-4"&gt;
          &lt;h2&gt;Navigation&lt;/h2&gt;
          &lt;nav&gt;...&lt;/nav&gt;
        &lt;/div&gt;
        &quot;&quot;&quot;
      end
    end
    """
  end

  template """
  <div class="max-w-4xl mx-auto p-6">
    <div class="flex items-center justify-between mb-6">
      <div>
        <h1 class="text-3xl font-bold">Flyover (Slideover) Demo</h1>
        <p class="text-gray-500 mt-1">Sliding panels that animate from screen edges</p>
      </div>
      <a href="/demos" class="text-indigo-600 hover:text-indigo-800">&larr; All Demos</a>
    </div>

    <div class="grid grid-cols-2 gap-6 mb-8">
      <!-- Left Flyover -->
      <div class="bg-white rounded-lg shadow p-6">
        <h2 class="font-semibold text-lg mb-4">Left Flyover</h2>
        <p class="text-gray-600 mb-4">Navigation drawer pattern - slides in from the left edge.</p>
        <button
          class="btn btn-primary"
          phx-click={Phoenix.LiveView.JS.dispatch("open-panel", to: "#nav-flyover-flyover", detail: %{open: true})}
        >
          Open Navigation
        </button>
      </div>

      <!-- Right Flyover -->
      <div class="bg-white rounded-lg shadow p-6">
        <h2 class="font-semibold text-lg mb-4">Right Flyover</h2>
        <p class="text-gray-600 mb-4">Detail panel pattern - slides in from the right edge.</p>
        <button
          class="btn btn-secondary"
          phx-click={Phoenix.LiveView.JS.dispatch("open-panel", to: "#details-flyover-flyover", detail: %{open: true})}
        >
          Open Details
        </button>
      </div>
    </div>

    <div class="bg-white rounded-lg shadow p-6 mb-8">
      <h2 class="font-semibold text-lg mb-4">Features</h2>
      <ul class="list-disc list-inside space-y-2 text-gray-600">
        <li><strong>Optimistic Animations:</strong> Panel slides immediately, no waiting for server</li>
        <li><strong>Multiple Directions:</strong> Slide from left, right, top, or bottom</li>
        <li><strong>Configurable Size:</strong> Width for horizontal, height for vertical</li>
        <li><strong>Backdrop:</strong> Optional click-to-close overlay</li>
        <li><strong>Escape Key:</strong> Close with keyboard</li>
        <li><strong>Focus Management:</strong> Traps focus within the panel</li>
      </ul>
    </div>

    <div class="bg-gray-100 rounded-lg p-6">
      <h2 class="font-semibold text-lg mb-4">Usage</h2>
      <pre class="bg-gray-800 text-green-400 p-4 rounded text-sm overflow-x-auto"><code>{usage_example()}</code></pre>
    </div>

    <!-- Navigation Flyover (Left) -->
    <.lavash_component
      module={DemoWeb.NavFlyover}
      id="nav-flyover"
    />

    <!-- Details Flyover (Right) -->
    <.lavash_component
      module={DemoWeb.DetailsFlyover}
      id="details-flyover"
    />
  </div>
  """
end
