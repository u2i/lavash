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
          <h2 class="text-xl font-semibold mb-4 border-b pb-2">Basics</h2>
          <div class="grid md:grid-cols-2 gap-4">
            <.demo_card
              href={~p"/lv/counter"}
              title="Counter (Reactive)"
              description="Using Lavash.Reactive graph engine — no DSL, but uses defgraph + rx."
            />
            <.demo_card
              href={~p"/lv/plain-counter"}
              title="Counter (Plain)"
              description="Plain LiveView + hand-coded JS hook. No Lavash Elixir, raw client primitives."
            />
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
