defmodule DemoWeb.LiveViewDemos.IndexLive do
  use DemoWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto py-8">
      <div class="text-center mb-12">
        <h1 class="text-4xl font-bold">Lavash.Reactive Demos</h1>
        <p class="text-base-content/70 mt-2">
          Using the reactive graph engine in plain LiveViews — no DSL required
        </p>
      </div>

      <div class="grid gap-6">
        <section>
          <h2 class="text-xl font-semibold mb-4 border-b pb-2">
            On-ramps: three ways to a counter
          </h2>
          <div class="grid md:grid-cols-2 gap-4">
            <.demo_card
              href={~p"/lv/explicit-counter"}
              title="Counter (Explicit)"
              description="use Lavash.LiveView.Explicit — reactive block, put_state, async derives. The smallest step up from plain LiveView."
            />
            <.demo_card
              href={~p"/lv/counter"}
              title="Counter (Reactive)"
              description="defgraph macro + Lavash.Reactive runtime calls — graph caching, explicit put/recompute."
            />
            <.demo_card
              href={~p"/lv/plain-counter"}
              title="Counter (Plain)"
              description="Plain LiveView + hand-coded JS hook. No Lavash Elixir, raw client primitives."
            />
          </div>
        </section>

        <section>
          <h2 class="text-xl font-semibold mb-4 border-b pb-2">State &amp; Data</h2>
          <div class="grid md:grid-cols-2 gap-4">
            <.demo_card
              href={~p"/lv/products"}
              title="Products (URL State)"
              description="URL-backed filters via hand-wired handle_params, async Ash read derive with stale-while-loading, PubSub invalidation."
            />
            <.demo_card
              href={~p"/lv/form-validation"}
              title="Form Validation"
              description="Per-field error derives written by hand in a reactive block; Ash submit for authoritative validation."
            />
          </div>
        </section>

        <section>
          <h2 class="text-xl font-semibold mb-4 border-b pb-2">What stays DSL-only</h2>
          <div class="card bg-base-200">
            <div class="card-body py-4 text-sm text-base-content/70 space-y-1">
              <p>
                The reactive graph (state, derives, async, batching, PubSub invalidation)
                is available without the DSL — that's what these demos show. The rest of
                Lavash is generated from the DSL and has no manual equivalent:
              </p>
              <ul class="list-disc list-inside space-y-1">
                <li>Optimistic client-side updates (transpiled rx, <code>data-lavash-*</code>)</li>
                <li>Component bindings (<code>bind=</code>, nested binding chains)</li>
                <li>Overlays (modals, flyovers) and their phase machine</li>
                <li>Stream-backed projections</li>
                <li>Ash form integration (generated validity/error fields)</li>
              </ul>
              <p>
                See the <a href="/" class="link">DSL demos</a> for those.
              </p>
            </div>
          </div>
        </section>
      </div>

      <div class="mt-12 text-center text-sm text-base-content/50">
        <a href="/" class="link">&larr; Back to DSL demos</a>
      </div>
    </div>
    """
  end

  defp demo_card(assigns) do
    ~H"""
    <a href={@href} class="card bg-base-200 hover:bg-base-300 transition-colors">
      <div class="card-body py-4">
        <h3 class="card-title text-base">{@title}</h3>
        <p class="text-sm text-base-content/70">{@description}</p>
      </div>
    </a>
    """
  end
end
