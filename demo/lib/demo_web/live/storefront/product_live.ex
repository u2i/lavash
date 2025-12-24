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
        &larr; Back to Coffees
      </a>

      <div class="grid md:grid-cols-2 gap-8">
        <div class="card bg-base-200 overflow-hidden">
          <figure>
            <img
              src={"https://images.unsplash.com/#{coffee_image(@product.roast_level)}?w=600&q=80"}
              alt={@product.name}
              class="w-full h-80 object-cover"
            />
          </figure>
        </div>

        <div class="space-y-6">
          <div>
            <div class="flex items-start justify-between gap-4">
              <h1 class="text-3xl font-bold">{@product.name}</h1>
              <.roast_badge level={@product.roast_level} />
            </div>
            <p class="text-lg text-base-content/70 mt-1">{@product.origin}</p>
          </div>

          <p class="text-base-content/80">{@product.description}</p>

          <div class="flex items-center gap-2">
            <span class="text-amber-500 text-lg">{"★" |> String.duplicate(round(Decimal.to_float(@product.rating)))}</span>
            <span class="text-base-content/70">{Decimal.to_string(@product.rating)} / 5</span>
          </div>

          <div class="card bg-base-200">
            <div class="card-body p-4">
              <h3 class="font-semibold text-sm uppercase tracking-wide text-base-content/60">Tasting Notes</h3>
              <p class="mt-1">{@product.tasting_notes}</p>
            </div>
          </div>

          <div class="flex items-center gap-4">
            <span class={["badge badge-lg", @product.in_stock && "badge-success", !@product.in_stock && "badge-error"]}>
              {if @product.in_stock, do: "In Stock", else: "Sold Out"}
            </span>
            <span class="text-sm text-base-content/60">{@product.weight_oz}oz bag</span>
          </div>

          <div class="divider"></div>

          <div class="flex items-center justify-between">
            <span class="text-3xl font-bold">${Decimal.to_string(@product.price)}</span>
            <button class="btn btn-primary btn-lg" disabled={!@product.in_stock}>
              {if @product.in_stock, do: "Add to Cart", else: "Notify Me"}
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp coffee_image(roast_level) do
    case roast_level do
      :light -> "photo-1495474472287-4d71bcdd2085"
      :medium -> "photo-1559056199-641a0ac8b55e"
      :medium_dark -> "photo-1509042239860-f550ce710b93"
      :dark -> "photo-1514432324607-a09d9b4aefdd"
      _ -> "photo-1447933601403-0c6688de566e"
    end
  end

  defp roast_badge(assigns) do
    {color, label} =
      case assigns.level do
        :light -> {"bg-amber-100 text-amber-800", "Light Roast"}
        :medium -> {"bg-orange-100 text-orange-800", "Medium Roast"}
        :medium_dark -> {"bg-orange-200 text-orange-900", "Medium-Dark Roast"}
        :dark -> {"bg-stone-700 text-stone-100", "Dark Roast"}
        _ -> {"bg-base-300 text-base-content", "Unknown"}
      end

    assigns = assign(assigns, color: color, label: label)

    ~H"""
    <span class={"text-sm px-3 py-1 rounded-full font-medium #{@color}"}>
      {@label}
    </span>
    """
  end
end
