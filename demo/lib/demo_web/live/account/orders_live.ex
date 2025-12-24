defmodule DemoWeb.Account.OrdersLive do
  use DemoWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center gap-4">
        <a href={~p"/account"} class="btn btn-ghost btn-sm">&larr;</a>
        <h1 class="text-2xl font-bold">Orders</h1>
      </div>

      <%= if @current_user do %>
        <div class="card bg-base-200">
          <div class="card-body text-center py-12">
            <p class="text-base-content/50">No orders yet.</p>
            <div class="mt-4">
              <a href={~p"/products"} class="btn btn-primary">Start Shopping</a>
            </div>
          </div>
        </div>
      <% else %>
        <div class="card bg-base-200">
          <div class="card-body text-center">
            <p class="text-base-content/70">Please sign in to view your orders.</p>
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
