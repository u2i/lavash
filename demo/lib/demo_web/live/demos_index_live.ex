defmodule DemoWeb.DemosIndexLive do
  use DemoWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto py-8">
      <div class="text-center mb-12">
        <h1 class="text-4xl font-bold">Lavash Demos</h1>
        <p class="text-base-content/70 mt-2">
          Explore optimistic UI patterns with Phoenix LiveView
        </p>
      </div>

      <div class="grid gap-6">
        <section>
          <h2 class="text-xl font-semibold mb-4 border-b pb-2">Optimistic Components</h2>
          <div class="grid md:grid-cols-2 gap-4">
            <.demo_card
              href={~p"/demos/toggle"}
              title="Toggle (LiveComponent)"
              description="Per-field optimistic updates using SyncedVar. Updates individual DOM values without re-rendering."
            />
            <.demo_card
              href={~p"/demos/tag-editor"}
              title="Tag Editor (ClientComponent)"
              description="Full client-side re-rendering for structural DOM changes like adding/removing tags."
            />
            <.demo_card
              href={~p"/demos/bindings"}
              title="ChipSet Bindings"
              description="Multi-select chips with parent state binding. Demonstrates bind/synced pattern."
            />
            <.demo_card
              href={~p"/demos/components"}
              title="Component Showcase"
              description="Overview of Lavash component patterns and their optimistic behaviors."
            />
            <.demo_card
              href={~p"/demos/flyover"}
              title="Flyover (Slideover)"
              description="Sliding panels from screen edges with optimistic open/close animations."
            />
          </div>
        </section>

        <section>
          <h2 class="text-xl font-semibold mb-4 border-b pb-2">State Management</h2>
          <div class="grid md:grid-cols-2 gap-4">
            <.demo_card
              href={~p"/demos/counter"}
              title="Counter"
              description="Basic state management with optimistic increment/decrement."
            />
            <.demo_card
              href={~p"/demos/form-validation"}
              title="Form Validation"
              description="Client-side validation via transpiled rx() calculations. Instant feedback."
            />
            <.demo_card
              href={~p"/demos/checkout"}
              title="Checkout (Shopify-style)"
              description="Full checkout form with card validation, Luhn check, and dynamic styling."
            />
            <.demo_card
              href={~p"/demos/products"}
              title="Products (URL State)"
              description="Product catalog with filters stored in URL. Shareable and bookmarkable."
            />
            <.demo_card
              href={~p"/demos/products-socket"}
              title="Products (Socket State)"
              description="Same catalog with filters in socket. Survives reconnect, lost on refresh."
            />
          </div>
        </section>

        <section>
          <h2 class="text-xl font-semibold mb-4 border-b pb-2">Full Application</h2>
          <div class="grid md:grid-cols-2 gap-4">
            <.demo_card
              href={~p"/storefront"}
              title="Coffee Shop Storefront"
              description="Complete e-commerce demo with products, categories, and cart."
            />
            <.demo_card
              href={~p"/admin"}
              title="Admin Dashboard"
              description="Product and category management with CRUD operations."
            />
          </div>
        </section>
      </div>

      <div class="mt-12 text-center text-sm text-base-content/50">
        <p>
          Built with
          <a href="https://hexdocs.pm/lavash" class="link">Lavash</a>
          +
          <a href="https://ash-hq.org" class="link">Ash</a>
          +
          <a href="https://phoenixframework.org" class="link">Phoenix</a>
        </p>
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
