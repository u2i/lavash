defmodule DemoWeb.NestingDemoLive do
  @moduledoc """
  Demo page showing various component nesting combinations with bindings.

  Demonstrates:
  1. LiveView → ClientComponent (direct)
  2. LiveView → Lavash.Component → ClientComponent (2-level)
  3. LiveView → Lavash.Component → Lavash.Component → ClientComponent (3-level)

  All bindings propagate changes back up through the component hierarchy
  using send_update with CID targeting.
  """
  use Lavash.LiveView

  import Lavash.Component.Helpers, only: [child_component: 1]
  import Lavash.LiveView.Helpers, only: [o: 1]

  # Three separate counters to demo different nesting levels
  state :direct_count, :integer, from: :ephemeral, default: 0, optimistic: true
  state :wrapped_count, :integer, from: :ephemeral, default: 0, optimistic: true
  state :deep_count, :integer, from: :ephemeral, default: 0, optimistic: true

  # Calculations that depend on the state to show reactivity
  calculate :total, rx(@direct_count + @wrapped_count + @deep_count)
  calculate :direct_doubled, rx(@direct_count * 2)
  calculate :wrapped_doubled, rx(@wrapped_count * 2)
  calculate :deep_doubled, rx(@deep_count * 2)

  render fn assigns ->
    ~L"""
    <div class="max-w-4xl mx-auto p-6">
      <div class="flex items-center justify-between mb-6">
        <div>
          <h1 class="text-3xl font-bold">Nesting Demo</h1>
          <p class="text-base-content/70 mt-1">
            Component binding chains at different nesting depths
          </p>
        </div>
        <a href="/" class="btn btn-ghost btn-sm">&larr; Demos</a>
      </div>

      <!-- Summary showing all reactive calculations -->
      <div class="bg-base-200 p-4 rounded-lg mb-8">
        <h2 class="font-semibold mb-3">LiveView State (reactive calculations)</h2>
        <div class="grid grid-cols-4 gap-4 text-center">
          <div>
            <.o field={:direct_count} value={@direct_count} tag="div" class="text-2xl font-mono" />
            <div class="text-xs text-base-content/50">Direct</div>
            <div class="text-xs text-base-content/30">×2 = <.o field={:direct_doubled} value={@direct_doubled} /></div>
          </div>
          <div>
            <.o field={:wrapped_count} value={@wrapped_count} tag="div" class="text-2xl font-mono" />
            <div class="text-xs text-base-content/50">Wrapped</div>
            <div class="text-xs text-base-content/30">×2 = <.o field={:wrapped_doubled} value={@wrapped_doubled} /></div>
          </div>
          <div>
            <.o field={:deep_count} value={@deep_count} tag="div" class="text-2xl font-mono" />
            <div class="text-xs text-base-content/50">Deep</div>
            <div class="text-xs text-base-content/30">×2 = <.o field={:deep_doubled} value={@deep_doubled} /></div>
          </div>
          <div class="border-l border-base-300 pl-4">
            <.o field={:total} value={@total} tag="div" class="text-2xl font-mono font-bold" />
            <div class="text-xs text-base-content/50">Total</div>
          </div>
        </div>
      </div>

      <div class="grid gap-6">
        <!-- Case 1: Direct binding (LiveView → ClientComponent) -->
        <section class="bg-base-100 p-6 rounded-lg border border-base-300">
          <h3 class="font-semibold mb-1">1. Direct Binding</h3>
          <p class="text-sm text-base-content/60 mb-4">
            LiveView → ClientComponent
          </p>
          <div class="flex items-center gap-4">
            <.live_component
              module={DemoWeb.Components.CounterControls}
              id="direct-counter"
              bind={[count: :direct_count]}
              count={@direct_count}
            />
            <div class="text-sm text-base-content/50">
              Binding: <code class="bg-base-200 px-1.5 py-0.5 rounded">count → direct_count</code>
            </div>
          </div>
        </section>

        <!-- Case 2: Single wrapper (LiveView → Lavash.Component → ClientComponent) -->
        <section class="bg-base-100 p-6 rounded-lg border border-base-300">
          <h3 class="font-semibold mb-1">2. Single Wrapper</h3>
          <p class="text-sm text-base-content/60 mb-4">
            LiveView → Lavash.Component → ClientComponent
          </p>
          <div class="flex items-center gap-4">
            <.live_component
              module={DemoWeb.Components.CounterWrapper}
              id="wrapped-counter"
              bind={[count: :wrapped_count]}
              count={@wrapped_count}
              __lavash_parent_version__={@__lavash_parent_version__}
            />
            <div class="text-sm text-base-content/50">
              <div>Binding chain:</div>
              <code class="bg-base-200 px-1.5 py-0.5 rounded text-xs">
                count → count → wrapped_count
              </code>
            </div>
          </div>
        </section>

        <!-- Case 3: Double wrapper (LiveView → Lavash.Component → Lavash.Component → ClientComponent) -->
        <section class="bg-base-100 p-6 rounded-lg border border-base-300">
          <h3 class="font-semibold mb-1">3. Double Wrapper (3-level nesting)</h3>
          <p class="text-sm text-base-content/60 mb-4">
            LiveView → Lavash.Component → Lavash.Component → ClientComponent
          </p>
          <div class="flex items-center gap-4">
            <.live_component
              module={DemoWeb.Components.DoubleWrapper}
              id="deep-counter"
              bind={[count: :deep_count]}
              count={@deep_count}
              __lavash_parent_version__={@__lavash_parent_version__}
            />
            <div class="text-sm text-base-content/50">
              <div>Binding chain:</div>
              <code class="bg-base-200 px-1.5 py-0.5 rounded text-xs">
                count → count → count → deep_count
              </code>
            </div>
          </div>
        </section>
      </div>

      <!-- Technical explanation -->
      <div class="mt-8 bg-info/10 p-4 rounded-lg text-sm">
        <h4 class="font-semibold mb-2">How it works</h4>
        <ul class="list-disc list-inside space-y-1 text-base-content/70">
          <li><strong>Client-side:</strong> Changes bubble up via <code>lavash-set</code> events to parent hooks</li>
          <li><strong>Server-side:</strong> Uses <code>send_update/2</code> with CID to route to parent Lavash.Components</li>
          <li>Lavash.Components check their binding map and propagate to their parent if bound</li>
          <li>Chain continues until reaching a LiveView, which receives the final value</li>
          <li>All calculations in the LiveView reactive graph update automatically</li>
        </ul>
      </div>
    </div>
    """
  end
end
