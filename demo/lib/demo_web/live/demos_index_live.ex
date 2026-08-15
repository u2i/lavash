defmodule DemoWeb.DemosIndexLive do
  @moduledoc """
  Single landing page for all demos.

  Demos are organized as three parallel structures — the same app
  expressed at three levels of the stack — and each row links its
  available implementations with colored pills:

  - **DSL** (`/dsl/*`): full lavash DSL — optimistic client-side
    updates, bindings, overlays, streams
  - **Reactive DSL** (`/reactive/*`): the declarative reactive layer
    (`reactive do` / `defgraph`) without the optimistic layer —
    server round-trips
  - **Builder** (`/builder/*`): lavash core API with no macros at
    all — explicit dependency lists, plain functions
  """
  use DemoWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-3xl mx-auto py-8 px-4">
      <div class="text-center mb-8">
        <h1 class="text-4xl font-bold">Lavash Demos</h1>
        <p class="text-base-content/70 mt-2">
          One demo set, three parallel implementations — pick a row, compare the styles
        </p>
      </div>

      <div class="flex flex-wrap justify-center gap-4 mb-10 text-sm">
        <span class="flex items-center gap-1.5">
          <span class="badge badge-primary badge-xs"></span> Full DSL (optimistic)
        </span>
        <span class="flex items-center gap-1.5">
          <span class="badge badge-secondary badge-xs"></span> Reactive DSL (no optimistic JS)
        </span>
        <span class="flex items-center gap-1.5">
          <span class="badge badge-accent badge-xs"></span> Builder (core API, no macros)
        </span>
      </div>

      <div class="grid gap-6">
        <section>
          <h2 class="text-xl font-semibold mb-4 border-b pb-2">Side by side</h2>
          <div class="space-y-3">
            <.demo_row
              title="Counter"
              description="State, derived values, async compute."
              links={[
                {:dsl, "DSL", ~p"/dsl/counter"},
                {:reactive, "Reactive · defgraph", ~p"/reactive/counter"},
                {:reactive, "Reactive · Explicit", ~p"/reactive/explicit-counter"},
                {:builder, "Builder", ~p"/builder/counter"},
                {:js, "Hand-coded JS", ~p"/js-counter"}
              ]}
            />
            <.demo_row
              title="Todos"
              description="CRUD on a real resource with cross-tab sync. The DSL adds stream projections and per-row optimistic predictions."
              links={[
                {:dsl, "DSL", ~p"/dsl/todos"},
                {:reactive, "Reactive", ~p"/reactive/todos"},
                {:builder, "Builder", ~p"/builder/todos"}
              ]}
            />
            <.demo_row
              title="Form Validation"
              description="Per-field errors and form validity. The DSL derives them from Ash constraints and validates client-side."
              links={[
                {:dsl, "DSL", ~p"/dsl/form-validation"},
                {:reactive, "Reactive", ~p"/reactive/form-validation"}
              ]}
            />
            <.demo_row
              title="Products"
              description="Filterable catalog with URL-backed state, async reads, and PubSub invalidation."
              links={[
                {:dsl, "DSL", ~p"/dsl/products"},
                {:dsl, "DSL · socket state", ~p"/dsl/products-socket"},
                {:builder, "Builder", ~p"/builder/products"}
              ]}
            />
          </div>
        </section>

        <section>
          <h2 class="text-xl font-semibold mb-4 border-b pb-2">DSL-only features</h2>
          <p class="text-sm text-base-content/60 mb-4">
            Generated from the DSL with no manual equivalent: optimistic JS, component
            bindings, overlays, streams.
          </p>
          <div class="space-y-3">
            <.demo_row
              title="Toggle"
              description="Per-field optimistic updates via SyncedVar."
              links={[{:dsl, "DSL", ~p"/dsl/toggle"}]}
            />
            <.demo_row
              title="Tag Editor"
              description="Client-side re-rendering for structural DOM changes."
              links={[{:dsl, "DSL", ~p"/dsl/tag-editor"}]}
            />
            <.demo_row
              title="ChipSet Bindings"
              description="Multi-select chips bound to parent state."
              links={[{:dsl, "DSL", ~p"/dsl/bindings"}]}
            />
            <.demo_row
              title="Nested Bindings"
              description="Binding chains at 1, 2, and 3 levels with bidirectional sync."
              links={[{:dsl, "DSL", ~p"/dsl/nesting"}]}
            />
            <.demo_row
              title="Flyover"
              description="Sliding panels with optimistic open/close animations."
              links={[{:dsl, "DSL", ~p"/dsl/flyover"}]}
            />
            <.demo_row
              title="Modal"
              description="Optimistic open, loading skeleton, async content."
              links={[{:dsl, "DSL", ~p"/dsl/modal"}]}
            />
            <.demo_row
              title="Component Showcase"
              description="Overview of lavash component patterns."
              links={[{:dsl, "DSL", ~p"/dsl/components"}]}
            />
            <.demo_row
              title="Client + Server Validation"
              description="Instant client errors from constraints, server errors after round-trip."
              links={[{:dsl, "DSL", ~p"/dsl/validation"}]}
            />
            <.demo_row
              title="Streaming Chat"
              description="Token streaming into a LiveView stream."
              links={[{:dsl, "DSL", ~p"/chat"}]}
            />
          </div>
        </section>

        <section>
          <h2 class="text-xl font-semibold mb-4 border-b pb-2">Full application</h2>
          <div class="space-y-3">
            <.demo_row
              title="Coffee Shop Storefront"
              description="Complete e-commerce flow: products, cart, checkout, orders."
              links={[{:dsl, "DSL", ~p"/storefront"}]}
            />
            <.demo_row
              title="Admin Dashboard"
              description="Product and category management."
              links={[{:dsl, "DSL", ~p"/admin"}]}
            />
          </div>
        </section>
      </div>

      <div class="mt-12 text-center text-sm text-base-content/50">
        <p>
          Built with <a href="https://hexdocs.pm/lavash" class="link">Lavash</a>
          + <a href="https://ash-hq.org" class="link">Ash</a>
          + <a href="https://phoenixframework.org" class="link">Phoenix</a>
        </p>
      </div>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :links, :list, required: true, doc: "list of {style, label, href} pill links"

  defp demo_row(assigns) do
    ~H"""
    <div class="card bg-base-200">
      <div class="card-body py-4 sm:flex-row sm:items-center sm:justify-between gap-3">
        <div>
          <h3 class="card-title text-base">{@title}</h3>
          <p class="text-sm text-base-content/70">{@description}</p>
        </div>
        <div class="flex flex-wrap gap-2 shrink-0">
          <a :for={{style, label, href} <- @links} href={href} class={pill_class(style)}>
            {label}
          </a>
        </div>
      </div>
    </div>
    """
  end

  defp pill_class(style) do
    base = "btn btn-xs rounded-full"

    case style do
      :dsl -> [base, "btn-primary"]
      :reactive -> [base, "btn-secondary"]
      :builder -> [base, "btn-accent"]
      :js -> [base, "btn-warning"]
    end
  end
end
