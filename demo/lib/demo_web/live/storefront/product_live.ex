defmodule DemoWeb.Storefront.ProductLive do
  use DemoWeb, :live_view

  alias Demo.Catalog.Product

  def mount(%{"product_id" => product_id}, _session, socket) do
    case Ash.get(Product, product_id) do
      {:ok, product} ->
        {:ok, assign(socket, product: product)}

      {:error, _} ->
        {:ok, push_navigate(socket, to: ~p"/products")}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <a href={~p"/products"} class="btn btn-ghost btn-sm">
        &larr; Back to Products
      </a>

      <div class="card bg-base-200">
        <div class="card-body">
          <h1 class="card-title text-3xl">{@product.name}</h1>
          <div class="flex items-center gap-2">
            <span class="text-yellow-500 text-lg">{"★" |> String.duplicate(round(Decimal.to_float(@product.rating)))}</span>
            <span class="text-base-content/70">{Decimal.to_string(@product.rating)} / 5</span>
          </div>

          <div class="mt-4">
            <span class={["badge", @product.in_stock && "badge-success", !@product.in_stock && "badge-error"]}>
              {if @product.in_stock, do: "In Stock", else: "Out of Stock"}
            </span>
          </div>

          <div class="divider"></div>

          <div class="flex justify-between items-center">
            <span class="text-2xl font-bold">
              ${Decimal.to_string(@product.price)}
            </span>
            <button class="btn btn-primary btn-lg" disabled={!@product.in_stock}>
              Add to Cart
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
