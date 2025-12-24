defmodule DemoWeb.StorefrontLive do
  use DemoWeb, :live_view

  alias Demo.Catalog.Product

  def mount(_params, _session, socket) do
    featured = Ash.read!(Product) |> Enum.take(3)
    {:ok, assign(socket, featured: featured)}
  end

  def render(assigns) do
    ~H"""
    <div class="space-y-12">
      <section class="text-center py-8">
        <div class="relative h-64 md:h-80 rounded-xl overflow-hidden mb-8">
          <img
            src="https://images.unsplash.com/photo-1447933601403-0c6688de566e?w=1200&q=80"
            alt="Fresh roasted coffee beans"
            class="w-full h-full object-cover"
          />
          <div class="absolute inset-0 bg-gradient-to-t from-base-100/90 to-transparent"></div>
        </div>
        <h1 class="text-5xl font-bold">Lavash Coffee</h1>
        <p class="text-xl text-base-content/70 mt-4 max-w-2xl mx-auto">
          Small batch, ethically sourced beans roasted fresh daily.
          From farm to cup, we obsess over every detail.
        </p>
        <div class="mt-8 flex gap-4 justify-center">
          <a href={~p"/products"} class="btn btn-primary btn-lg">
            Shop Coffees
          </a>
          <a href={~p"/products"} class="btn btn-outline btn-lg">
            Our Story
          </a>
        </div>
      </section>

      <section>
        <h2 class="text-2xl font-bold text-center mb-6">Featured Roasts</h2>
        <div class="grid grid-cols-1 md:grid-cols-3 gap-6">
          <%= for product <- @featured do %>
            <a href={~p"/products/#{product.id}"} class="card bg-base-200 hover:shadow-xl transition-all hover:-translate-y-1">
              <figure class="px-4 pt-4">
                <img
                  src={"https://images.unsplash.com/photo-1559056199-641a0ac8b55e?w=400&q=80&seed=#{product.id}"}
                  alt={product.name}
                  class="w-full h-40 object-cover rounded-lg"
                />
              </figure>
              <div class="card-body pt-4">
                <h3 class="card-title">{product.name}</h3>
                <p class="text-sm text-base-content/60">{product.origin}</p>
                <p class="text-sm text-base-content/70 mt-1 line-clamp-2">{product.tasting_notes}</p>
                <div class="card-actions justify-between items-center mt-4">
                  <span class="text-xl font-bold">${Decimal.to_string(product.price)}</span>
                  <span class="btn btn-sm btn-primary">Add to Cart</span>
                </div>
              </div>
            </a>
          <% end %>
        </div>
        <div class="text-center mt-8">
          <a href={~p"/products"} class="btn btn-ghost">View All Coffees →</a>
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
            <a href={~p"/products"} class="btn btn-primary">Start Subscription</a>
          </div>
        </div>
      </section>

      <section class="text-center py-8 border-t border-base-300">
        <p class="text-xs text-base-content/40">
          Demo store built with
          <a href="https://hexdocs.pm/lavash" class="link">Lavash</a>
          +
          <a href="https://ash-hq.org" class="link">Ash</a>
          +
          <a href="https://phoenixframework.org" class="link">Phoenix</a>
          ·
          <a href={~p"/demos/counter"} class="link">Technical Demos</a>
        </p>
      </section>
    </div>
    """
  end

end
