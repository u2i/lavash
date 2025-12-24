defmodule DemoWeb.StorefrontLive do
  use DemoWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <section class="text-center py-12">
        <h1 class="text-4xl font-bold mb-4">Welcome to the Store</h1>
        <p class="text-lg text-base-content/70 mb-8">
          Browse our collection of products
        </p>
        <a href={~p"/products"} class="btn btn-primary btn-lg">
          Shop Now
        </a>
      </section>

      <section class="grid grid-cols-1 md:grid-cols-3 gap-6">
        <div class="card bg-base-200">
          <div class="card-body">
            <h2 class="card-title">Featured Products</h2>
            <p>Check out our latest arrivals and bestsellers.</p>
            <div class="card-actions justify-end">
              <a href={~p"/products"} class="btn btn-sm btn-ghost">Browse</a>
            </div>
          </div>
        </div>

        <div class="card bg-base-200">
          <div class="card-body">
            <h2 class="card-title">Your Account</h2>
            <p>View orders, manage settings, and more.</p>
            <div class="card-actions justify-end">
              <a href={~p"/account"} class="btn btn-sm btn-ghost">My Account</a>
            </div>
          </div>
        </div>

        <div class="card bg-base-200">
          <div class="card-body">
            <h2 class="card-title">Demos</h2>
            <p>Technical demos showcasing Lavash features.</p>
            <div class="card-actions justify-end">
              <a href={~p"/demos/counter"} class="btn btn-sm btn-ghost">View Demos</a>
            </div>
          </div>
        </div>
      </section>
    </div>
    """
  end
end
