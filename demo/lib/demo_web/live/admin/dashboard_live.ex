defmodule DemoWeb.Admin.DashboardLive do
  use DemoWeb, :live_view

  alias Demo.Catalog.{Product, Category}
  alias Demo.Orders.Order

  def mount(_params, _session, socket) do
    product_count = Ash.count!(Product)
    category_count = Ash.count!(Category)
    order_count = Ash.count!(Order)
    pending_count = pending_count()
    revenue = revenue_to_date()

    {:ok,
     assign(socket,
       product_count: product_count,
       category_count: category_count,
       order_count: order_count,
       pending_count: pending_count,
       revenue: revenue
     )}
  end

  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <h1 class="text-2xl font-bold">Admin Dashboard</h1>

      <!-- Top stats -->
      <div class="grid grid-cols-1 md:grid-cols-4 gap-6">
        <div class="card bg-base-200">
          <div class="card-body py-4">
            <p class="text-xs text-base-content/50 uppercase">Revenue</p>
            <p class="text-3xl font-bold font-mono">${@revenue}</p>
          </div>
        </div>
        <div class="card bg-base-200">
          <div class="card-body py-4">
            <p class="text-xs text-base-content/50 uppercase">Orders</p>
            <p class="text-3xl font-bold">{@order_count}</p>
          </div>
        </div>
        <div class="card bg-base-200">
          <div class="card-body py-4">
            <p class="text-xs text-base-content/50 uppercase">Pending</p>
            <p class="text-3xl font-bold">{@pending_count}</p>
          </div>
        </div>
        <div class="card bg-base-200">
          <div class="card-body py-4">
            <p class="text-xs text-base-content/50 uppercase">Products</p>
            <p class="text-3xl font-bold">{@product_count}</p>
          </div>
        </div>
      </div>

      <!-- Section cards -->
      <div class="grid grid-cols-1 md:grid-cols-3 gap-6">
        <div class="card bg-base-200">
          <div class="card-body">
            <h2 class="card-title">Orders</h2>
            <p class="text-sm text-base-content/70">
              View, filter, and update order status. {@pending_count} pending fulfilment.
            </p>
            <div class="card-actions justify-end mt-2">
              <a href={~p"/admin/orders"} class="btn btn-sm btn-primary">
                Manage Orders
              </a>
            </div>
          </div>
        </div>

        <div class="card bg-base-200">
          <div class="card-body">
            <h2 class="card-title">Products</h2>
            <p class="text-sm text-base-content/70">
              {@product_count} products in the catalog.
            </p>
            <div class="card-actions justify-end mt-2">
              <a href={~p"/admin/products"} class="btn btn-sm btn-ghost">Manage</a>
            </div>
          </div>
        </div>

        <div class="card bg-base-200">
          <div class="card-body">
            <h2 class="card-title">Categories</h2>
            <p class="text-sm text-base-content/70">
              {@category_count} categories defined.
            </p>
            <div class="card-actions justify-end mt-2">
              <a href={~p"/admin/categories"} class="btn btn-sm btn-ghost">Manage</a>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp pending_count do
    Order
    |> Ash.Query.for_read(:all_for_admin, %{status: :pending})
    |> Ash.read!()
    |> length()
  end

  defp revenue_to_date do
    # Sum of totals for non-cancelled orders. Decimal arithmetic, so
    # we accumulate in a Decimal.
    Order
    |> Ash.read!()
    |> Enum.reject(&(&1.status == :cancelled))
    |> Enum.reduce(Decimal.new(0), fn order, acc -> Decimal.add(acc, order.total) end)
    |> Decimal.round(2)
    |> Decimal.to_string()
  end
end
