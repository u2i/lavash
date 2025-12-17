defmodule DemoWeb.ProductsLive do
  use Lavash.LiveView
  import Lavash.LiveView.Helpers

  alias Demo.Catalog.Product

  # All filter state stored in URL - shareable, bookmarkable, back/forward works
  state :search, :string, from: :url, default: ""
  state :category, :string, from: :url, default: ""
  state :in_stock, :boolean, from: :url, default: nil
  state :min_price, :integer, from: :url, default: nil
  state :max_price, :integer, from: :url, default: nil
  state :min_rating, :integer, from: :url, default: nil

  # Products - auto-maps state fields to :list action arguments
  # The action's arguments (search, category, in_stock, etc.) match our state field names
  read :products, Product, :list do
    async false
    arg :category, transform: &(if &1 == "", do: nil, else: &1)
  end

  # Categories - simple read with no arguments
  read :categories, Product, :list_categories do
    async false
  end

  # No longer needed - can compute directly in template or use a simple derive

  derive :result_count do
    argument :products, result(:products)
    run fn %{products: products}, _ ->
      length(products)
    end
  end

  derive :has_filters do
    argument :search, state(:search)
    argument :category, state(:category)
    argument :in_stock, state(:in_stock)
    argument :min_price, state(:min_price)
    argument :max_price, state(:max_price)
    argument :min_rating, state(:min_rating)
    run fn f, _ ->
      f.search != "" or f.category != "" or f.in_stock != nil or
      f.min_price != nil or f.max_price != nil or f.min_rating != nil
    end
  end

  actions do
    action :set_search, [:value] do
      set :search, & &1.params.value
    end

    action :set_category, [:value] do
      set :category, & &1.params.value
    end

    action :set_in_stock, [:value] do
      set :in_stock, & &1.params.value
    end

    action :set_min_price, [:value] do
      set :min_price, & &1.params.value
    end

    action :set_max_price, [:value] do
      set :max_price, & &1.params.value
    end

    action :set_min_rating, [:value] do
      set :min_rating, & &1.params.value
    end

    action :clear_filters do
      set :search, ""
      set :category, ""
      set :in_stock, nil
      set :min_price, nil
      set :max_price, nil
      set :min_rating, nil
    end

    # Modal action - invoke the modal's :open action
    action :open_edit, [:id] do
      invoke "product-edit-modal", :open,
        module: DemoWeb.ProductEditModal,
        params: [product_id: {:param, :id}]
    end
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-6xl mx-auto p-6">
      <div class="flex items-center justify-between mb-6">
        <div>
          <h1 class="text-3xl font-bold">Product Catalog (URL State)</h1>
          <p class="text-gray-500 mt-1">Filter state stored in URL - try bookmarking or sharing</p>
        </div>
        <div class="flex gap-4">
          <a href="/products-socket" class="text-indigo-600 hover:text-indigo-800">Socket State Version</a>
          <a href="/" class="text-indigo-600 hover:text-indigo-800">&larr; Back to Counter</a>
        </div>
      </div>

      <div class="grid grid-cols-4 gap-6">
        <!-- Filters Sidebar -->
        <div class="col-span-1 bg-white rounded-lg shadow p-4 h-fit">
          <div class="flex items-center justify-between mb-4">
            <h2 class="font-semibold text-lg">Filters</h2>
            <button
              :if={@has_filters}
              phx-click="clear_filters"
              class="text-sm text-red-600 hover:text-red-800"
            >
              Clear all
            </button>
          </div>

          <div class="space-y-4">
            <!-- Search -->
            <div>
              <label class="block text-sm font-medium text-gray-700 mb-1">Search</label>
              <form phx-change="set_search">
                <input
                  type="text"
                  name="value"
                  value={@search}
                  placeholder="Search products..."
                  phx-debounce="300"
                  class="w-full px-3 py-2 border rounded-md text-sm"
                />
              </form>
            </div>

            <!-- Category -->
            <div>
              <label class="block text-sm font-medium text-gray-700 mb-1">Category</label>
              <form phx-change="set_category">
                <select name="value" class="w-full px-3 py-2 border rounded-md text-sm">
                  <option value="">All Categories</option>
                  <option :for={cat <- @categories} value={cat} selected={@category == cat}>
                    {cat}
                  </option>
                </select>
              </form>
            </div>

            <!-- In Stock -->
            <div>
              <label class="block text-sm font-medium text-gray-700 mb-1">Availability</label>
              <form phx-change="set_in_stock">
                <select name="value" class="w-full px-3 py-2 border rounded-md text-sm">
                  <option value="" selected={@in_stock == nil}>All</option>
                  <option value="true" selected={@in_stock == true}>In Stock</option>
                  <option value="false" selected={@in_stock == false}>Out of Stock</option>
                </select>
              </form>
            </div>

            <!-- Price Range -->
            <div>
              <label class="block text-sm font-medium text-gray-700 mb-1">Price Range</label>
              <div class="flex gap-2">
                <form phx-change="set_min_price" class="flex-1">
                  <input
                    type="number"
                    name="value"
                    value={@min_price}
                    placeholder="Min"
                    class="w-full px-3 py-2 border rounded-md text-sm"
                  />
                </form>
                <span class="self-center text-gray-400">-</span>
                <form phx-change="set_max_price" class="flex-1">
                  <input
                    type="number"
                    name="value"
                    value={@max_price}
                    placeholder="Max"
                    class="w-full px-3 py-2 border rounded-md text-sm"
                  />
                </form>
              </div>
            </div>

            <!-- Min Rating -->
            <div>
              <label class="block text-sm font-medium text-gray-700 mb-1">Minimum Rating</label>
              <form phx-change="set_min_rating">
                <select name="value" class="w-full px-3 py-2 border rounded-md text-sm">
                  <option value="" selected={@min_rating == nil}>Any Rating</option>
                  <option :for={r <- [4, 3, 2, 1]} value={r} selected={@min_rating == r}>
                    {r}+ stars
                  </option>
                </select>
              </form>
            </div>
          </div>

          <!-- Current URL display -->
          <div class="mt-6 pt-4 border-t">
            <p class="text-xs text-gray-400 mb-1">Current filter URL:</p>
            <code class="text-xs bg-gray-100 p-2 rounded block break-all">
              {build_url(assigns)}
            </code>
          </div>
        </div>

        <!-- Products Grid -->
        <div class="col-span-3">
          <div class="flex items-center justify-between mb-4">
            <p class="text-gray-600">
              Showing <span class="font-semibold">{@result_count}</span> products
            </p>
          </div>

          <div class="grid grid-cols-3 gap-4">
            <div
              :for={product <- @products}
              class="bg-white rounded-lg shadow p-4 hover:shadow-md transition-shadow"
            >
              <div class="flex items-start justify-between">
                <h3 class="font-medium text-gray-900">{product.name}</h3>
                <span class={[
                  "text-xs px-2 py-1 rounded-full",
                  product.in_stock && "bg-green-100 text-green-800",
                  !product.in_stock && "bg-red-100 text-red-800"
                ]}>
                  {if product.in_stock, do: "In Stock", else: "Out of Stock"}
                </span>
              </div>
              <p class="text-sm text-gray-500 mt-1">{product.category}</p>
              <div class="flex items-center justify-between mt-3">
                <span class="text-lg font-bold text-indigo-600">
                  ${Decimal.to_string(product.price)}
                </span>
                <span class="text-sm text-yellow-600">
                  {"★" |> String.duplicate(round(Decimal.to_float(product.rating)))}
                  <span class="text-gray-400 ml-1">{Decimal.to_string(product.rating)}</span>
                </span>
              </div>
              <button
                phx-click="open_edit"
                phx-value-id={product.id}
                class="mt-3 block w-full text-center text-sm text-indigo-600 hover:text-indigo-800 border-t pt-3"
              >
                Edit
              </button>
            </div>
          </div>

          <div :if={@result_count == 0} class="text-center py-12 bg-white rounded-lg shadow">
            <p class="text-gray-500 text-lg">No products match your filters</p>
            <button
              phx-click="clear_filters"
              class="mt-4 text-indigo-600 hover:text-indigo-800"
            >
              Clear all filters
            </button>
          </div>
        </div>
      </div>

      <.lavash_component
        module={DemoWeb.ProductEditModal}
        id="product-edit-modal"
      />
    </div>
    """
  end

  defp build_url(assigns) do
    params =
      %{}
      |> maybe_add("search", assigns.search, "")
      |> maybe_add("category", assigns.category, "")
      |> maybe_add("in_stock", assigns.in_stock, nil)
      |> maybe_add("min_price", assigns.min_price, nil)
      |> maybe_add("max_price", assigns.max_price, nil)
      |> maybe_add("min_rating", assigns.min_rating, nil)

    if params == %{} do
      "/products"
    else
      "/products?" <> URI.encode_query(params)
    end
  end

  defp maybe_add(params, _key, value, default) when value == default, do: params
  defp maybe_add(params, key, value, _default), do: Map.put(params, key, value)
end
