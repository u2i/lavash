defmodule DemoWeb.Admin.OrderDetailLive do
  @moduledoc """
  Admin order detail. Shows the full order (line items, addresses,
  payment) and lets the operator transition status:

      pending  →  paid  →  shipped  →  delivered
                                      ↘ cancelled

  Transitions are exposed as action buttons that fire
  `update_status` (and `:cancel` for the dead-end). The buttons
  for invalid transitions are hidden via calculated booleans.
  """
  use Lavash.LiveView

  use Phoenix.VerifiedRoutes,
    endpoint: DemoWeb.Endpoint,
    router: DemoWeb.Router,
    statics: DemoWeb.static_paths()

  alias Demo.Orders.Order

  state :order_id, :string, from: :url

  read :order, Order, :admin_detail do
    argument :id, state(:order_id)
    async false
  end

  calculate :found?, rx(@order != nil), optimistic: false

  # Status-transition gates
  calculate :can_mark_paid?, rx(@order != nil and @order.status == :pending), optimistic: false
  calculate :can_mark_shipped?, rx(@order != nil and @order.status == :paid), optimistic: false

  calculate :can_mark_delivered?,
            rx(@order != nil and @order.status == :shipped),
            optimistic: false

  calculate :can_cancel?,
            rx(@order != nil and @order.status in [:pending, :paid]),
            optimistic: false

  actions do
    action :mark_paid do
      effect fn state -> transition(state.order, :paid) end
    end

    action :mark_shipped do
      effect fn state -> transition(state.order, :shipped) end
    end

    action :mark_delivered do
      effect fn state -> transition(state.order, :delivered) end
    end

    action :cancel_order do
      effect fn state -> transition(state.order, :cancelled) end
    end
  end

  template do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center gap-4">
        <.link navigate={~p"/admin/orders"} class="btn btn-ghost btn-sm">&larr; Orders</.link>
        <h1 class="text-2xl font-bold">Order Detail</h1>
      </div>

      <%= if @found? do %>
        <!-- Header -->
        <div class="card bg-base-200">
          <div class="card-body">
            <div class="flex flex-col md:flex-row md:items-center md:justify-between gap-2">
              <div>
                <p class="text-xs text-base-content/50 uppercase">Order</p>
                <code class="text-sm">#{String.slice(@order.id, 0, 12)}</code>
                <p class="text-sm text-base-content/70 mt-1">
                  <span :if={@order.user}>{@order.user.email} · </span>
                  Placed {Calendar.strftime(@order.inserted_at, "%B %-d, %Y at %-I:%M %p")}
                </p>
              </div>
              <div>
                <span class={status_badge_class(@order.status)}>
                  {@order.status |> Atom.to_string() |> String.capitalize()}
                </span>
              </div>
            </div>
          </div>
        </div>

        <!-- Status actions -->
        <div
          :if={@can_mark_paid? or @can_mark_shipped? or @can_mark_delivered? or @can_cancel?}
          class="card bg-base-200"
        >
          <div class="card-body">
            <h2 class="card-title">Update status</h2>
            <div class="flex flex-wrap gap-2">
              <button
                :if={@can_mark_paid?}
                phx-click="mark_paid"
                class="btn btn-info btn-sm"
              >
                Mark as paid
              </button>
              <button
                :if={@can_mark_shipped?}
                phx-click="mark_shipped"
                class="btn btn-primary btn-sm"
              >
                Mark as shipped
              </button>
              <button
                :if={@can_mark_delivered?}
                phx-click="mark_delivered"
                class="btn btn-success btn-sm"
              >
                Mark as delivered
              </button>
              <button
                :if={@can_cancel?}
                phx-click="cancel_order"
                data-confirm="Cancel this order? The customer will be notified."
                class="btn btn-error btn-outline btn-sm"
              >
                Cancel order
              </button>
            </div>
          </div>
        </div>

        <!-- Items -->
        <div class="card bg-base-200">
          <div class="card-body">
            <h2 class="card-title">Items</h2>
            <div class="overflow-x-auto">
              <table class="table">
                <thead>
                  <tr>
                    <th>Product</th>
                    <th class="text-right">Qty</th>
                    <th class="text-right">Unit price</th>
                    <th class="text-right">Line total</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={item <- @order.items}>
                    <td>{item.product_name}</td>
                    <td class="text-right">{item.quantity}</td>
                    <td class="text-right font-mono">
                      ${Decimal.to_string(item.unit_price)}
                    </td>
                    <td class="text-right font-mono">
                      ${line_total(item)}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <div class="border-t border-base-300 mt-4 pt-4 space-y-1 text-sm">
              <div class="flex justify-between">
                <span class="text-base-content/70">Subtotal</span>
                <span class="font-mono">${Decimal.to_string(@order.subtotal)}</span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/70">Tax</span>
                <span class="font-mono">${Decimal.to_string(@order.tax)}</span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/70">Shipping</span>
                <span class="font-mono">${Decimal.to_string(@order.shipping)}</span>
              </div>
              <div class="flex justify-between font-bold text-base pt-2 border-t border-base-300/50">
                <span>Total</span>
                <span class="font-mono">${Decimal.to_string(@order.total)}</span>
              </div>
            </div>
          </div>
        </div>

        <!-- Addresses & payment -->
        <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
          <div :if={@order.shipping_address} class="card bg-base-200">
            <div class="card-body">
              <h2 class="card-title">Shipping</h2>
              <.address_block address={@order.shipping_address} />
            </div>
          </div>
          <div :if={@order.billing_address} class="card bg-base-200">
            <div class="card-body">
              <h2 class="card-title">Billing</h2>
              <.address_block address={@order.billing_address} />
            </div>
          </div>
        </div>

        <div :if={@order.card_last_four} class="card bg-base-200">
          <div class="card-body">
            <h2 class="card-title">Payment</h2>
            <p class="text-sm">
              {String.capitalize(@order.payment_method)} ending in {@order.card_last_four}
            </p>
          </div>
        </div>
      <% else %>
        <div class="card bg-base-200">
          <div class="card-body text-center py-12">
            <h2 class="text-lg font-semibold">Order not found</h2>
            <div class="mt-4">
              <.link navigate={~p"/admin/orders"} class="btn btn-primary">
                Back to Orders
              </.link>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp address_block(assigns) do
    ~H"""
    <div class="text-sm space-y-0.5">
      <p class="font-medium">{@address.first_name} {@address.last_name}</p>
      <p :if={@address.company} class="text-base-content/70">{@address.company}</p>
      <p>{@address.address}</p>
      <p :if={@address.apartment}>{@address.apartment}</p>
      <p>{@address.city}, {@address.state} {@address.zip}</p>
      <p :if={@address.country}>{@address.country}</p>
      <p :if={@address.phone} class="text-base-content/70 mt-1">{@address.phone}</p>
    </div>
    """
  end

  defp transition(nil, _new_status), do: :ok

  defp transition(%Order{} = order, new_status) do
    order
    |> Ash.Changeset.for_update(:update_status, %{status: new_status})
    |> Ash.update!()
  end

  defp line_total(item) do
    item.unit_price
    |> Decimal.mult(item.quantity)
    |> Decimal.to_string()
  end

  defp status_badge_class(:pending), do: "badge badge-warning"
  defp status_badge_class(:paid), do: "badge badge-info"
  defp status_badge_class(:shipped), do: "badge badge-primary"
  defp status_badge_class(:delivered), do: "badge badge-success"
  defp status_badge_class(:cancelled), do: "badge badge-error"
  defp status_badge_class(_), do: "badge"
end
