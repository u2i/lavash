defmodule DemoWeb.ToggleDemoLive do
  @moduledoc """
  Demo showing the Toggle component using SyncedVar.

  This demonstrates:
  - SyncedVar-based optimistic updates
  - Instant UI response with stale patch rejection
  - Clean binding to parent state
  """
  use Lavash.LiveView

  # Boolean states with optimistic updates
  state :feature_enabled, :boolean, default: false, optimistic: true
  state :dark_mode, :boolean, default: false, optimistic: true
  state :notifications, :boolean, default: true, optimistic: true

  # Server-side derive to show round-trip timing
  derive :server_timestamp do
    argument :feature_enabled, state(:feature_enabled)
    argument :dark_mode, state(:dark_mode)
    argument :notifications, state(:notifications)

    run fn _args, _ ->
      DateTime.utc_now() |> DateTime.to_time() |> Time.truncate(:second) |> Time.to_string()
    end
  end

  def render(assigns) do
    ~L"""
    <div class="max-w-4xl mx-auto p-6">
      <div class="flex items-center justify-between mb-6">
        <div>
          <h1 class="text-3xl font-bold">Toggle Demo</h1>
          <p class="text-gray-500 mt-1">
            SyncedVar-based optimistic toggles
          </p>
        </div>
        <a href="/" class="text-indigo-600 hover:text-indigo-800">&larr; Demos</a>
      </div>

      <div class="bg-blue-50 p-4 rounded-lg mb-6 text-sm">
        <p class="text-blue-800">
          <strong>How it works:</strong> Enable latency simulation (bottom right), then toggle switches.
          The switch flips instantly (optimistic), while server content updates after the round-trip.
          Rapid toggles are handled correctly - stale server patches are rejected.
        </p>
      </div>

      <div class="grid grid-cols-2 gap-6">
        <!-- Left: Toggle controls -->
        <div class="bg-gray-50 p-6 rounded-lg">
          <h2 class="font-semibold mb-6">Settings (Optimistic)</h2>

          <div class="space-y-6">
            <div class="flex items-center justify-between">
              <div>
                <h3 class="text-sm font-medium text-gray-900">Feature Flag</h3>
                <p class="text-xs text-gray-500">Enable the new experimental feature</p>
              </div>
              <.live_component
                module={Lavash.Components.SyncedToggle}
                id="feature-toggle"
                bind={[value: :feature_enabled]}
                value={@feature_enabled}
              />
            </div>

            <div class="flex items-center justify-between">
              <div>
                <h3 class="text-sm font-medium text-gray-900">Dark Mode</h3>
                <p class="text-xs text-gray-500">Switch to dark theme</p>
              </div>
              <.live_component
                module={Lavash.Components.SyncedToggle}
                id="dark-mode-toggle"
                bind={[value: :dark_mode]}
                value={@dark_mode}
              />
            </div>

            <div class="flex items-center justify-between">
              <div>
                <h3 class="text-sm font-medium text-gray-900">Notifications</h3>
                <p class="text-xs text-gray-500">Receive push notifications</p>
              </div>
              <.live_component
                module={Lavash.Components.SyncedToggle}
                id="notifications-toggle"
                bind={[value: :notifications]}
                value={@notifications}
              />
            </div>
          </div>

          <p class="text-xs text-gray-400 mt-6">
            Each toggle uses SyncedVar under the hood. Click rapidly to test stale patch rejection.
          </p>
        </div>

        <!-- Right: Server state display -->
        <div class="bg-white p-6 rounded-lg border">
          <h2 class="font-semibold mb-4">Server State</h2>

          <div class="space-y-4 text-sm">
            <div>
              <span class="text-gray-600">Last update:</span>
              <span class="font-mono bg-gray-100 px-2 py-1 rounded ml-2">
                {@server_timestamp}
              </span>
            </div>

            <div class="border-t pt-4">
              <h3 class="text-xs font-medium text-gray-500 uppercase mb-2">Current Values</h3>
              <div class="space-y-2">
                <div class="flex justify-between">
                  <span class="text-gray-600">feature_enabled:</span>
                  <code class={[
                    "px-2 py-0.5 rounded text-xs",
                    @feature_enabled && "bg-green-100 text-green-800",
                    !@feature_enabled && "bg-gray-100 text-gray-600"
                  ]}>
                    {to_string(@feature_enabled)}
                  </code>
                </div>
                <div class="flex justify-between">
                  <span class="text-gray-600">dark_mode:</span>
                  <code class={[
                    "px-2 py-0.5 rounded text-xs",
                    @dark_mode && "bg-green-100 text-green-800",
                    !@dark_mode && "bg-gray-100 text-gray-600"
                  ]}>
                    {to_string(@dark_mode)}
                  </code>
                </div>
                <div class="flex justify-between">
                  <span class="text-gray-600">notifications:</span>
                  <code class={[
                    "px-2 py-0.5 rounded text-xs",
                    @notifications && "bg-green-100 text-green-800",
                    !@notifications && "bg-gray-100 text-gray-600"
                  ]}>
                    {to_string(@notifications)}
                  </code>
                </div>
              </div>
            </div>
          </div>

          <p class="text-xs text-gray-400 mt-6">
            This shows the server's authoritative state. Compare with the toggle positions during latency.
          </p>
        </div>
      </div>

      <!-- Architecture explanation -->
      <div class="mt-8 bg-green-50 p-6 rounded-lg">
        <h2 class="font-semibold mb-3">Architecture: SyncedVar</h2>
        <div class="text-sm text-green-800">
          <p class="mb-2">
            Each toggle uses a <code class="bg-green-100 px-1 rounded">SyncedVar</code> instance to track:
          </p>
          <ul class="list-disc list-inside space-y-1 ml-2">
            <li><code>value</code> - the optimistic client value</li>
            <li><code>confirmedValue</code> - last server-confirmed value</li>
            <li><code>version</code> / <code>confirmedVersion</code> - for detecting stale patches</li>
          </ul>
          <p class="mt-3">
            When you toggle rapidly, <code>setOptimistic()</code> bumps the version.
            Server patches are only accepted via <code>serverSet()</code> if no operations are pending.
          </p>
        </div>
      </div>
    </div>
    """
  end
end
