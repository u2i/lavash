defmodule DemoWeb.Admin.DashboardLive do
  use DemoWeb, :live_view

  alias Demo.Catalog.{Product, Category}

  def mount(_params, _session, socket) do
    product_count = Ash.read!(Product) |> length()
    category_count = Ash.read!(Category) |> length()

    {:ok, assign(socket, product_count: product_count, category_count: category_count)}
  end

  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <h1 class="text-2xl font-bold">Admin Dashboard</h1>

      <div class="grid grid-cols-1 md:grid-cols-3 gap-6">
        <div class="card bg-base-200">
          <div class="card-body">
            <h2 class="card-title text-4xl">{@product_count}</h2>
            <p>Products</p>
            <div class="card-actions justify-end">
              <a href={~p"/admin/products"} class="btn btn-sm btn-ghost">Manage</a>
            </div>
          </div>
        </div>

        <div class="card bg-base-200">
          <div class="card-body">
            <h2 class="card-title text-4xl">{@category_count}</h2>
            <p>Categories</p>
            <div class="card-actions justify-end">
              <a href={~p"/admin/categories"} class="btn btn-sm btn-ghost">Manage</a>
            </div>
          </div>
        </div>

        <div class="card bg-base-200">
          <div class="card-body">
            <h2 class="card-title text-4xl">0</h2>
            <p>Orders</p>
            <div class="card-actions justify-end">
              <span class="btn btn-sm btn-ghost btn-disabled">Coming soon</span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
