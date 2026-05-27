defmodule DemoWeb.Account.OrdersLive do
  @moduledoc """
  Customer order history. Lists the signed-in user's orders most
  recent first, with status, placed-at, and total. Each row links
  to the per-order detail page.

  Uses lavash patterns: `read :orders, ..., :for_user` with a state
  argument, calculated `:has_orders?` boolean for empty-state
  rendering, and an `optimistic: false` read since order data is
  authoritative (no client-side mirror).
  """
  use Lavash.LiveView

  use Phoenix.VerifiedRoutes,
    endpoint: DemoWeb.Endpoint,
    router: DemoWeb.Router,
    statics: DemoWeb.static_paths()

  alias Demo.Orders.Order

  state :_user_id, :string, from: :ephemeral

  # `current_user` is injected by the AshAuthentication on_mount hook.
  # Declaring it lets templates reference `@current_user` and lets
  # rx() see it.
  state :current_user, :map, from: :assigns, assigns_key: :current_user

  read :orders, Order, :for_user do
    argument :user_id, state(:_user_id)
    async false
  end

  calculate :has_orders?, rx(@orders != nil and @orders != []), optimistic: false

  mount do
    run fn socket ->
      user = socket.assigns[:current_user]
      Lavash.Socket.put_state(socket, :_user_id, user && user.id)
    end
  end

  template do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center gap-4">
        <.link navigate={~p"/account"} class="btn btn-ghost btn-sm">&larr;</.link>
        <h1 class="text-2xl font-bold">Orders</h1>
      </div>

      <%= if @current_user do %>
        <%= if @has_orders? do %>
          <div class="card bg-base-200">
            <div class="card-body p-0">
              <table class="table">
                <thead>
                  <tr>
                    <th>Order</th>
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
                        navigate={~p"/account/orders/#{order.id}"}
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
              <p class="text-base-content/50">No orders yet.</p>
              <div class="mt-4">
                <.link
                  navigate={~p"/storefront/products"}
                  class="btn btn-primary"
                >
                  Start Shopping
                </.link>
              </div>
            </div>
          </div>
        <% end %>
      <% else %>
        <div class="card bg-base-200">
          <div class="card-body text-center">
            <p class="text-base-content/70">Please sign in to view your orders.</p>
            <div class="card-actions justify-center mt-4">
              <a href="/sign-in" class="btn btn-primary">Sign In</a>
            </div>
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
