defmodule DemoWeb.Account.DashboardLive do
  use DemoWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  def render(assigns) do
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

        <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
          <a href={~p"/account/orders"} class="card bg-base-200 hover:bg-base-300 transition-colors">
            <div class="card-body">
              <h2 class="card-title">Orders</h2>
              <p>View your order history and track shipments.</p>
            </div>
          </a>

          <a href={~p"/account/settings"} class="card bg-base-200 hover:bg-base-300 transition-colors">
            <div class="card-body">
              <h2 class="card-title">Settings</h2>
              <p>Manage your account preferences and details.</p>
            </div>
          </a>
        </div>
      <% else %>
        <div class="card bg-base-200">
          <div class="card-body text-center">
            <h2 class="card-title justify-center">Sign in to view your account</h2>
            <p class="text-base-content/70">Access your orders, settings, and more.</p>
            <div class="card-actions justify-center mt-4">
              <a href={~p"/sign-in"} class="btn btn-primary">Sign In</a>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
