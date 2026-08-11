defmodule DemoWeb.StorefrontLive do
  @moduledoc """
  Storefront landing page — on the same cart infra as the rest of the
  store: the CartFlyover component owns trigger + badge + panel, and
  the featured cards' Add to Cart drives the flyover's `:add_item`
  upsert through `invoke`, so badge, row, and totals all predict in
  the same tick (issue #74 — the old page was a plain LiveView whose
  Add to Cart was a decorative span inside the card link).
  """
  use Lavash.LiveView
  import Lavash.LiveView.Helpers

  use Phoenix.VerifiedRoutes,
    endpoint: DemoWeb.Endpoint,
    router: DemoWeb.Router,
    statics: DemoWeb.static_paths()

  alias Demo.Cart.Cart
  alias Demo.Catalog.Product

  state :cart_id, :string, from: :ephemeral
  state :cart_open, :any, from: :ephemeral, default: nil, optimistic: true

  read :products, Product do
    async false
  end

  calculate :featured, rx(Enum.take(@products, 3)), optimistic: false

  actions do
    # Same shape as the products index: open the flyover optimistically
    # and invoke its :add_item upsert with the product's display fields
    # so the prediction is complete either branch (existing row ticks,
    # new row renders fully).
    action :add_to_cart, [:product_id, :name, :origin, :unit_price] do
      set :cart_open, true

      invoke "cart-flyover", :add_item,
        module: DemoWeb.CartFlyover,
        params: [
          product_id: {:param, :product_id},
          qty: 1,
          name: {:param, :name},
          origin: {:param, :origin},
          unit_price: {:param, :unit_price}
        ]
    end
  end

  mount do
    run fn socket -> find_or_create_cart(socket) end
  end

  defp find_or_create_cart(socket) do
    user = socket.assigns[:current_user]

    cart_id =
      if user do
        case Cart |> Ash.Query.for_read(:for_user, %{user_id: user.id}) |> Ash.read_one() do
          {:ok, nil} ->
            {:ok, cart} =
              Cart
              |> Ash.Changeset.for_create(:create, %{}, actor: user)
              |> Ash.create()

            cart.id

          {:ok, cart} ->
            cart.id

          _ ->
            nil
        end
      else
        nil
      end

    Lavash.Socket.put_state(socket, :cart_id, cart_id)
  end

  template do
    ~H"""
    <div class="space-y-12">
      <div class="flex justify-end pt-2">
        <%!-- Cart: trigger (icon + optimistic badge) AND flyover panel,
             all owned by the component — this page just places it. --%>
        <.lavash_component
          module={DemoWeb.CartFlyover}
          id="cart-flyover"
          cart_id={@cart_id}
          open={@cart_open}
          bind={[open: :cart_open]}
        />
      </div>

      <section class="text-center py-8">
        <div class="relative h-64 md:h-80 rounded-xl overflow-hidden mb-8">
          <img
            src="https://images.unsplash.com/photo-1447933601403-0c6688de566e?w=1200&q=80"
            alt="Fresh roasted coffee beans"
            class="w-full h-full object-cover"
          />
          <div class="absolute inset-0 bg-gradient-to-t from-base-100/90 to-transparent"></div>
        </div>
        <h1 class="text-4xl md:text-5xl font-bold">Lavash Coffee</h1>
        <p class="text-xl text-base-content/70 mt-4 max-w-2xl mx-auto">
          Small batch, ethically sourced beans roasted fresh daily.
          From farm to cup, we obsess over every detail.
        </p>
        <div class="mt-8 flex gap-4 justify-center">
          <a href={~p"/storefront/products"} class="btn btn-primary btn-lg">
            Shop Coffees
          </a>
          <a href={~p"/storefront/products"} class="btn btn-outline btn-lg">
            Our Story
          </a>
        </div>
      </section>

      <section>
        <h2 class="text-2xl font-bold text-center mb-6">Featured Roasts</h2>
        <div class="grid grid-cols-1 md:grid-cols-3 gap-6">
          <%= for product <- @featured do %>
            <div class="card bg-base-200 hover:shadow-xl transition-all hover:-translate-y-1">
              <%!-- Navigation region: image + copy link to the product page.
                   The action row lives OUTSIDE the anchor — a button nested
                   in a link is invalid HTML and clicks fall through to
                   navigation (the original #74 bug). --%>
              <a href={~p"/storefront/products/#{product.id}"}>
                <figure class="px-4 pt-4">
                  <img
                    src={"https://images.unsplash.com/photo-1559056199-641a0ac8b55e?w=400&q=80&seed=#{product.id}"}
                    alt={product.name}
                    class="w-full h-40 object-cover rounded-lg"
                  />
                </figure>
                <div class="card-body pt-4 pb-0">
                  <h3 class="card-title">{product.name}</h3>
                  <p class="text-sm text-base-content/60">{product.origin}</p>
                  <p class="text-sm text-base-content/70 mt-1 line-clamp-2">
                    {product.tasting_notes}
                  </p>
                </div>
              </a>
              <div class="card-body pt-2">
                <div class="card-actions justify-between items-center">
                  <span class="text-xl font-bold">${Decimal.to_string(product.price)}</span>
                  <%= if product.in_stock do %>
                    <button
                      type="button"
                      class="btn btn-sm btn-primary"
                      phx-click="add_to_cart"
                      phx-value-product_id={product.id}
                      phx-value-name={product.name}
                      phx-value-origin={product.origin}
                      phx-value-unit_price={Decimal.to_string(product.price)}
                    >
                      Add to Cart
                    </button>
                  <% else %>
                    <span class="btn btn-sm btn-disabled">Sold Out</span>
                  <% end %>
                </div>
              </div>
            </div>
          <% end %>
        </div>
        <div class="text-center mt-8">
          <a href={~p"/storefront/products"} class="btn btn-ghost">View All Coffees →</a>
        </div>
      </section>

      <section class="py-8">
        <div class="divider text-base-content/40">WHY LAVASH</div>
      </section>

      <section class="grid md:grid-cols-3 gap-8 text-center">
        <div>
          <div class="text-5xl mb-4">🌍</div>
          <h3 class="font-bold text-lg">Direct Trade</h3>
          <p class="text-sm text-base-content/70 mt-2">
            We partner directly with farmers, ensuring fair wages and sustainable practices.
          </p>
        </div>

        <div>
          <div class="text-5xl mb-4">🔥</div>
          <h3 class="font-bold text-lg">Roasted Fresh</h3>
          <p class="text-sm text-base-content/70 mt-2">
            Every order is roasted within 48 hours of shipping. Peak freshness, guaranteed.
          </p>
        </div>

        <div>
          <div class="text-5xl mb-4">🚚</div>
          <h3 class="font-bold text-lg">Free Shipping</h3>
          <p class="text-sm text-base-content/70 mt-2">
            On all orders over $35. Subscribe and save 15% on every delivery.
          </p>
        </div>
      </section>

      <section class="card bg-base-200">
        <div class="card-body text-center py-12">
          <h2 class="text-2xl font-bold">Subscribe & Save</h2>
          <p class="text-base-content/70 max-w-md mx-auto mt-2">
            Never run out of coffee. Get your favorite roasts delivered on your schedule and save 15%.
          </p>
          <div class="mt-6">
            <a href={~p"/storefront/products"} class="btn btn-primary">Start Subscription</a>
          </div>
        </div>
      </section>

      <section class="text-center py-8 border-t border-base-300">
        <p class="text-xs text-base-content/40">
          Demo store built with <a href="https://hexdocs.pm/lavash" class="link">Lavash</a>
          + <a href="https://ash-hq.org" class="link">Ash</a>
          + <a href="https://phoenixframework.org" class="link">Phoenix</a>
          · <a href={~p"/"} class="link">Technical Demos</a>
        </p>
      </section>
    </div>
    """
  end
end
