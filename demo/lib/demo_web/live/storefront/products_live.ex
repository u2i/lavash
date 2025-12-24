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
      <div class="flex justify-between items-center">
        <h1 class="text-2xl font-bold">Products</h1>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
        <%= for product <- @products do %>
          <a href={~p"/products/#{product.id}"} class="card bg-base-200 hover:bg-base-300 transition-colors">
            <div class="card-body">
              <h2 class="card-title">{product.name}</h2>
              <div class="flex items-center gap-2 text-sm text-base-content/70">
                <span class="text-yellow-500">{"★" |> String.duplicate(round(Decimal.to_float(product.rating)))}</span>
                <span>{Decimal.to_string(product.rating)}</span>
              </div>
              <div class="card-actions justify-between items-center mt-4">
                <span class="text-lg font-semibold">
                  ${Decimal.to_string(product.price)}
                </span>
                <span class="btn btn-sm btn-primary">View</span>
              </div>
            </div>
          </a>
        <% end %>
      </div>

      <%= if @products == [] do %>
        <div class="text-center py-12 text-base-content/50">
          <p>No products available yet.</p>
        </div>
      <% end %>
    </div>
    """
  end
end
