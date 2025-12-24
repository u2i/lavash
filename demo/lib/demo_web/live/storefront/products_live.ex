defmodule DemoWeb.Storefront.ProductsLive do
  use DemoWeb, :live_view

  alias Demo.Catalog.Product

  def mount(_params, _session, socket) do
    products = Ash.read!(Product)
    {:ok, assign(socket, products: products)}
  end

  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="text-center py-4">
        <h1 class="text-3xl font-bold">Our Coffees</h1>
        <p class="text-base-content/70 mt-2">Freshly roasted, ethically sourced</p>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
        <%= for product <- @products do %>
          <a href={~p"/products/#{product.id}"} class="card bg-base-200 hover:shadow-lg transition-all hover:-translate-y-1">
            <figure class="px-4 pt-4">
              <img
                src={"https://images.unsplash.com/#{coffee_image(product.roast_level)}?w=400&q=80"}
                alt={product.name}
                class="w-full h-40 object-cover rounded-lg"
              />
            </figure>
            <div class="card-body pt-4">
              <div class="flex justify-between items-start">
                <div>
                  <h2 class="card-title text-lg">{product.name}</h2>
                  <p class="text-sm text-base-content/60">{product.origin}</p>
                </div>
                <.roast_badge level={product.roast_level} />
              </div>

              <p class="text-sm text-base-content/70 mt-2 line-clamp-2">
                {product.tasting_notes}
              </p>

              <div class="flex items-center gap-1 mt-2">
                <span class="text-amber-500 text-sm">{"★" |> String.duplicate(round(Decimal.to_float(product.rating)))}</span>
                <span class="text-xs text-base-content/50">{Decimal.to_string(product.rating)}</span>
              </div>

              <div class="card-actions justify-between items-center mt-4 pt-4 border-t border-base-300">
                <div>
                  <span class="text-lg font-bold">${Decimal.to_string(product.price)}</span>
                  <span class="text-xs text-base-content/50">/ {product.weight_oz}oz</span>
                </div>
                <%= if product.in_stock do %>
                  <span class="btn btn-sm btn-primary">Add to Cart</span>
                <% else %>
                  <span class="btn btn-sm btn-disabled">Sold Out</span>
                <% end %>
              </div>
            </div>
          </a>
        <% end %>
      </div>

      <%= if @products == [] do %>
        <div class="text-center py-12 text-base-content/50">
          <p>No coffees available yet.</p>
        </div>
      <% end %>
    </div>
    """
  end

  defp coffee_image(roast_level) do
    # Different coffee images for different roast levels
    case roast_level do
      :light -> "photo-1495474472287-4d71bcdd2085"   # Light pour over
      :medium -> "photo-1559056199-641a0ac8b55e"    # Coffee beans
      :medium_dark -> "photo-1509042239860-f550ce710b93" # Espresso cup
      :dark -> "photo-1514432324607-a09d9b4aefdd"   # Dark roast beans
      _ -> "photo-1447933601403-0c6688de566e"       # Default beans
    end
  end

  defp roast_badge(assigns) do
    {color, label} =
      case assigns.level do
        :light -> {"bg-amber-100 text-amber-800", "Light"}
        :medium -> {"bg-orange-100 text-orange-800", "Medium"}
        :medium_dark -> {"bg-orange-200 text-orange-900", "Med-Dark"}
        :dark -> {"bg-stone-700 text-stone-100", "Dark"}
        _ -> {"bg-base-300 text-base-content", "Unknown"}
      end

    assigns = assign(assigns, color: color, label: label)

    ~H"""
    <span class={"text-xs px-2 py-1 rounded-full font-medium #{@color}"}>
      {@label}
    </span>
    """
  end
end
