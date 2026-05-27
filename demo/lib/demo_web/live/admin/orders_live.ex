defmodule DemoWeb.Admin.OrdersLive do
  @moduledoc """
  Admin order list: every order in the system, newest first, with
  a status filter. Each row links to the per-order admin detail
  page where status transitions happen.

  Demonstrates lavash patterns:
    * `read :orders, ..., :all_for_admin` with an optional URL-backed
      `:status_filter` argument (the table re-runs the read on
      filter change)
    * Stateless paging via state (`page`) tied to a URL param
    * Calculated `:has_orders?` for the empty-state branch
  """
  use Lavash.LiveView

  use Phoenix.VerifiedRoutes,
    endpoint: DemoWeb.Endpoint,
    router: DemoWeb.Router,
    statics: DemoWeb.static_paths()

  alias Demo.Orders.Order

  state :status_filter, :atom,
    from: :url,
    default: nil,
    optimistic: true,
    setter: true

  read :orders, Order, :all_for_admin do
    argument :status, state(:status_filter)
    async false
  end

  calculate :has_orders?, rx(@orders != nil and @orders != []), optimistic: false
  calculate :total_count, rx(length(@orders || [])), optimistic: false

  actions do
    action :clear_filter do
      set :status_filter, nil
    end

    action :filter_pending do
      set :status_filter, :pending
    end

    action :filter_paid do
      set :status_filter, :paid
    end

    action :filter_shipped do
      set :status_filter, :shipped
    end

    action :filter_delivered do
      set :status_filter, :delivered
    end

    action :filter_cancelled do
      set :status_filter, :cancelled
    end
  end

  template do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between gap-4">
        <div class="flex items-center gap-4">
          <.link navigate={~p"/admin"} class="btn btn-ghost btn-sm">&larr;</.link>
          <h1 class="text-2xl font-bold">Orders</h1>
        </div>
        <p class="text-sm text-base-content/60">
          {@total_count} {if @total_count == 1, do: "order", else: "orders"}
        </p>
      </div>

      <!-- Filter chips -->
      <div class="flex flex-wrap gap-2 items-center">
        <span class="text-sm text-base-content/60 mr-2">Filter:</span>
        <button
          phx-click="clear_filter"
          class={["btn btn-sm", if(@status_filter == nil, do: "btn-primary", else: "btn-ghost")]}
        >
          All
        </button>
        <button
          phx-click="filter_pending"
          class={["btn btn-sm", if(@status_filter == :pending, do: "btn-warning", else: "btn-ghost")]}
        >
          Pending
        </button>
        <button
          phx-click="filter_paid"
          class={["btn btn-sm", if(@status_filter == :paid, do: "btn-info", else: "btn-ghost")]}
        >
          Paid
        </button>
        <button
          phx-click="filter_shipped"
          class={["btn btn-sm", if(@status_filter == :shipped, do: "btn-primary", else: "btn-ghost")]}
        >
          Shipped
        </button>
        <button
          phx-click="filter_delivered"
          class={["btn btn-sm", if(@status_filter == :delivered, do: "btn-success", else: "btn-ghost")]}
        >
          Delivered
        </button>
        <button
          phx-click="filter_cancelled"
          class={["btn btn-sm", if(@status_filter == :cancelled, do: "btn-error", else: "btn-ghost")]}
        >
          Cancelled
        </button>
      </div>

      <!-- Order table -->
      <%= if @has_orders? do %>
        <div class="card bg-base-200">
          <div class="card-body p-0">
            <table class="table">
              <thead>
                <tr>
                  <th>Order</th>
                  <th>Customer</th>
                  <th>Placed</th>
                  <th>Status</th>
                  <th class="text-right">Total</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={order <- @orders} class="hover">
                  <td>
                    <code class="text-xs">#{String.slice(order.id, 0, 8)}</code>
                  </td>
                  <td class="text-sm">
                    <span :if={order.user}>{order.user.email}</span>
                    <span :if={!order.user} class="text-base-content/40">(deleted user)</span>
                  </td>
                  <td class="text-sm text-base-content/70">
                    {Calendar.strftime(order.inserted_at, "%b %-d, %Y")}
                  </td>
                  <td>
                    <span class={status_badge_class(order.status)}>
                      {order.status |> Atom.to_string() |> String.capitalize()}
                    </span>
                  </td>
                  <td class="text-right font-mono">
                    ${Decimal.to_string(order.total)}
                  </td>
                  <td>
                    <.link
                      navigate={~p"/admin/orders/#{order.id}"}
                      class="btn btn-ghost btn-sm"
                    >
                      View
                    </.link>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      <% else %>
        <div class="card bg-base-200">
          <div class="card-body text-center py-12">
            <p class="text-base-content/50">
              <%= if @status_filter do %>
                No orders with status {@status_filter}.
              <% else %>
                No orders yet.
              <% end %>
            </p>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp status_badge_class(:pending), do: "badge badge-warning"
  defp status_badge_class(:paid), do: "badge badge-info"
  defp status_badge_class(:shipped), do: "badge badge-primary"
  defp status_badge_class(:delivered), do: "badge badge-success"
  defp status_badge_class(:cancelled), do: "badge badge-error"
  defp status_badge_class(_), do: "badge"
end
