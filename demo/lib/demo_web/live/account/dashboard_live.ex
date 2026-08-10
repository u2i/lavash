defmodule DemoWeb.Account.DashboardLive do
  @moduledoc """
  Customer account dashboard. Shows recent orders, saved address
  count, and links to the rest of the account area.

  Uses lavash patterns: two `read` ops (orders + addresses) gated
  on the user_id ephemeral state, calculated counts driving the
  UI.
  """
  use Lavash.LiveView

  use Phoenix.VerifiedRoutes,
    endpoint: DemoWeb.Endpoint,
    router: DemoWeb.Router,
    statics: DemoWeb.static_paths()

  alias Demo.Orders.{Address, Order}

  state :_user_id, :string, from: :ephemeral
  state :current_user, :map, from: :assigns, assigns_key: :current_user

  read :orders, Order, :for_user do
    argument :user_id, state(:_user_id)
    async false
  end

  read :addresses, Address, :for_user do
    argument :user_id, state(:_user_id)
    async false
  end

  calculate :order_count, rx(length(@orders || [])), optimistic: false
  calculate :address_count, rx(length(@addresses || [])), optimistic: false
  calculate :recent_orders, rx(Enum.take(@orders || [], 3)), optimistic: false
  calculate :has_orders?, rx(@order_count > 0), optimistic: false

  mount do
    run fn socket ->
      user = socket.assigns[:current_user]
      Lavash.Socket.put_state(socket, :_user_id, user && user.id)
    end
  end

  template do
    ~H"""
    <div class="space-y-6">
      <h1 class="text-2xl font-bold">My Account</h1>

      <%= if @current_user do %>
        <div class="card bg-base-200">
          <div class="card-body">
            <h2 class="card-title">Welcome back!</h2>
            <p>Signed in as {@current_user.email}</p>
          </div>
        </div>

        <!-- Quick stats -->
        <div class="grid grid-cols-2 gap-4">
          <div class="card bg-base-200">
            <div class="card-body py-4">
              <p class="text-xs text-base-content/50 uppercase">Orders</p>
              <p class="text-3xl font-bold">{@order_count}</p>
            </div>
          </div>
          <div class="card bg-base-200">
            <div class="card-body py-4">
              <p class="text-xs text-base-content/50 uppercase">Saved addresses</p>
              <p class="text-3xl font-bold">{@address_count}</p>
            </div>
          </div>
        </div>

        <!-- Recent orders -->
        <div class="card bg-base-200">
          <div class="card-body">
            <div class="flex items-center justify-between">
              <h2 class="card-title">Recent Orders</h2>
              <.link
                navigate={~p"/account/orders"}
                class="text-sm link link-hover"
              >
                View all →
              </.link>
            </div>

            <%= if @has_orders? do %>
              <ul class="divide-y divide-base-300/40 -mx-4">
                <li :for={order <- @recent_orders} class="px-4 py-3 flex items-center justify-between">
                  <div class="flex items-center gap-3 text-sm">
                    <code class="text-xs text-base-content/60">
                      #{String.slice(order.id, 0, 8)}
                    </code>
                    <span class="text-base-content/70">
                      {Calendar.strftime(order.inserted_at, "%b %-d")}
                    </span>
                    <span class={status_badge_class(order.status)}>
                      {order.status |> Atom.to_string() |> String.capitalize()}
                    </span>
                  </div>
                  <div class="flex items-center gap-3">
                    <span class="font-mono text-sm">
                      ${Decimal.to_string(order.total)}
                    </span>
                    <.link
                      navigate={~p"/account/orders/#{order.id}"}
                      class="btn btn-ghost btn-xs"
                    >
                      View
                    </.link>
                  </div>
                </li>
              </ul>
            <% else %>
              <div class="text-center py-6 text-base-content/50">
                <p class="text-sm">No orders yet.</p>
                <.link
                  navigate={~p"/storefront/products"}
                  class="btn btn-primary btn-sm mt-3"
                >
                  Start Shopping
                </.link>
              </div>
            <% end %>
          </div>
        </div>

        <!-- Quick actions -->
        <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
          <.link
            navigate={~p"/account/orders"}
            class="card bg-base-200 hover:bg-base-300 transition-colors"
          >
            <div class="card-body">
              <h2 class="card-title">All Orders</h2>
              <p>View your full order history and track shipments.</p>
            </div>
          </.link>

          <.link
            navigate={~p"/account/settings"}
            class="card bg-base-200 hover:bg-base-300 transition-colors"
          >
            <div class="card-body">
              <h2 class="card-title">Settings</h2>
              <p>Manage saved addresses and account preferences.</p>
            </div>
          </.link>
        </div>
      <% else %>
        <div class="card bg-base-200">
          <div class="card-body text-center">
            <h2 class="card-title justify-center">
              Sign in to view your account
            </h2>
            <p class="text-base-content/70">
              Access your orders, settings, and saved addresses.
            </p>
            <div class="card-actions justify-center mt-4">
              <a href="/sign-in" class="btn btn-primary">Sign In</a>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp status_badge_class(:pending), do: "badge badge-warning badge-sm"
  defp status_badge_class(:paid), do: "badge badge-info badge-sm"
  defp status_badge_class(:shipped), do: "badge badge-primary badge-sm"
  defp status_badge_class(:delivered), do: "badge badge-success badge-sm"
  defp status_badge_class(:cancelled), do: "badge badge-error badge-sm"
  defp status_badge_class(_), do: "badge badge-sm"
end
