defmodule DemoWeb.DetailsFlyover do
  @moduledoc """
  A Lavash Component demonstrating a right-sliding Flyover for detail panels.

  This flyover slides in from the right and shows detail information.

  Opening the flyover from client-side:
  - JS.dispatch("open-panel", to: "#details-flyover-flyover", detail: %{open: true})

  ## Example usage

      <.lavash_component
        module={DemoWeb.DetailsFlyover}
        id="details-flyover"
      />
  """
  use Lavash.Component, extensions: [Lavash.Overlay.Flyover.Dsl]

  import Lavash.Overlay.Flyover.Helpers, only: [flyover_close_button: 1]

  # Configure flyover behavior - slides from right
  flyover do
    open_field :open
    slide_from :right
    width :md
  end

  render fn assigns ->
    ~H"""
    <div class="h-full flex flex-col">
      <div class="flex items-center justify-between p-4 border-b border-base-300">
        <h2 class="text-lg font-bold">Product Details</h2>
        <.flyover_close_button id={@__flyover_id__} myself={@myself} />
      </div>

      <div class="flex-1 overflow-auto p-4 space-y-6">
        <!-- Product Image Placeholder -->
        <div class="aspect-square bg-base-200 rounded-lg flex items-center justify-center">
          <svg class="w-24 h-24 text-base-300" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 16l4.586-4.586a2 2 0 012.828 0L16 16m-2-2l1.586-1.586a2 2 0 012.828 0L20 14m-6-6h.01M6 20h12a2 2 0 002-2V6a2 2 0 00-2-2H6a2 2 0 00-2 2v12a2 2 0 002 2z" />
          </svg>
        </div>

        <!-- Product Info -->
        <div>
          <h3 class="text-xl font-bold">Example Product</h3>
          <p class="text-2xl font-bold text-primary mt-2">$99.99</p>
        </div>

        <div class="space-y-2">
          <p class="text-base-content/70">
            This is an example detail panel that slides in from the right edge of the screen.
            Perfect for showing product details, user profiles, settings, or any secondary content.
          </p>
        </div>

        <div class="divider"></div>

        <!-- Specifications -->
        <div>
          <h4 class="font-semibold mb-3">Specifications</h4>
          <dl class="space-y-2">
            <div class="flex justify-between">
              <dt class="text-base-content/70">Category</dt>
              <dd class="font-medium">Electronics</dd>
            </div>
            <div class="flex justify-between">
              <dt class="text-base-content/70">SKU</dt>
              <dd class="font-medium">DEMO-001</dd>
            </div>
            <div class="flex justify-between">
              <dt class="text-base-content/70">Availability</dt>
              <dd class="badge badge-success badge-sm">In Stock</dd>
            </div>
            <div class="flex justify-between">
              <dt class="text-base-content/70">Rating</dt>
              <dd class="font-medium">4.5 / 5.0</dd>
            </div>
          </dl>
        </div>
      </div>

      <div class="p-4 border-t border-base-300 space-y-3">
        <button class="btn btn-primary w-full">Add to Cart</button>
        <button class="btn btn-outline w-full" phx-click={@on_close}>Close</button>
      </div>
    </div>
    """
  end
end
