defmodule DemoWeb.Admin.ProductsLive do
  use Lavash.LiveView
  use Phoenix.VerifiedRoutes, endpoint: DemoWeb.Endpoint, router: DemoWeb.Router
  import Lavash.LiveView.Helpers

  alias Demo.Catalog.{Category, Product}

  state :search, :string, from: :url, default: "", setter: true
  state :category_id, {:uuid, "cat"}, from: :url, default: nil, setter: true
  state :in_stock, :boolean, from: :url, default: nil, setter: true

  read :products, Product, :list do
    async false
    invalidate :pubsub
  end

  read :category_options, Category do
    async false
    as_options label: :name, value: :id
  end

  derive :result_count do
    argument :products, result(:products)
    run fn %{products: products}, _ -> length(products) end
  end

  derive :has_filters do
    argument :search, state(:search)
    argument :category_id, state(:category_id)
    argument :in_stock, state(:in_stock)

    run fn f, _ ->
      f.search != "" or f.category_id != nil or f.in_stock != nil
    end
  end

  actions do
    action :clear_filters do
      set :search, ""
      set :category_id, nil
      set :in_stock, nil
    end
  end

  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-bold">Products</h1>
        <a href={~p"/admin/products/new"} class="btn btn-primary">Add Product</a>
      </div>

      <div class="card bg-base-200">
        <div class="card-body">
          <div class="flex flex-wrap gap-4 items-end">
            <div class="form-control flex-1 min-w-48">
              <label class="label"><span class="label-text">Search</span></label>
              <form phx-change="set_search">
                <input
                  type="text"
                  name="value"
                  value={@search}
                  placeholder="Search products..."
                  phx-debounce="300"
                  class="input input-bordered w-full"
                />
              </form>
            </div>

            <div class="form-control w-48">
              <label class="label"><span class="label-text">Category</span></label>
              <form phx-change="set_category_id">
                <select name="value" class="select select-bordered w-full">
                  <option value="">All Categories</option>
                  <option :for={{name, id} <- @category_options} value={id} selected={@category_id == id}>
                    {name}
                  </option>
                </select>
              </form>
            </div>

            <div class="form-control w-40">
              <label class="label"><span class="label-text">Stock</span></label>
              <form phx-change="set_in_stock">
                <select name="value" class="select select-bordered w-full">
                  <option value="" selected={@in_stock == nil}>All</option>
                  <option value="true" selected={@in_stock == true}>In Stock</option>
                  <option value="false" selected={@in_stock == false}>Out of Stock</option>
                </select>
              </form>
            </div>

            <button :if={@has_filters} phx-click="clear_filters" class="btn btn-ghost">
              Clear
            </button>
          </div>
        </div>
      </div>

      <p class="text-sm text-base-content/70">
        Showing {@result_count} products
      </p>

      <div class="overflow-x-auto">
        <table class="table table-zebra">
          <thead>
            <tr>
              <th>Name</th>
              <th>Category</th>
              <th>Price</th>
              <th>Stock</th>
              <th>Rating</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={product <- @products}>
              <td class="font-medium">{product.name}</td>
              <td>{category_name(@category_options, product.category_id)}</td>
              <td>${Decimal.to_string(product.price)}</td>
              <td>
                <span class={["badge", product.in_stock && "badge-success", !product.in_stock && "badge-error"]}>
                  {if product.in_stock, do: "In Stock", else: "Out"}
                </span>
              </td>
              <td>{Decimal.to_string(product.rating)}</td>
              <td>
                <a href={~p"/admin/products/#{product.id}/edit"} class="btn btn-ghost btn-sm">
                  Edit
                </a>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div :if={@result_count == 0} class="text-center py-12 text-base-content/50">
        <p>No products found.</p>
        <button :if={@has_filters} phx-click="clear_filters" class="btn btn-ghost mt-4">
          Clear filters
        </button>
      </div>
    </div>
    """
  end

  defp category_name(options, category_id) do
    case Enum.find(options, fn {_name, id} -> id == category_id end) do
      nil -> "Uncategorized"
      {name, _id} -> name
    end
  end
end
