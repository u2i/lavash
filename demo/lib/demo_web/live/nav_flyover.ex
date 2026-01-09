defmodule DemoWeb.NavFlyover do
  @moduledoc """
  A Lavash Component demonstrating the Flyover (slideover) extension.

  This flyover slides in from the left and contains navigation links.

  Opening the flyover from client-side:
  - JS.dispatch("open-panel", to: "#nav-flyover-flyover", detail: %{open: true})

  ## Example usage

      <.lavash_component
        module={DemoWeb.NavFlyover}
        id="nav-flyover"
      />
  """
  use Lavash.Component, extensions: [Lavash.Overlay.Flyover.Dsl]

  import Lavash.Overlay.Flyover.Helpers, only: [flyover_close_button: 1]

  # Configure flyover behavior
  flyover do
    open_field :open
    slide_from :left
    width :sm
  end

  render fn assigns ->
    ~H"""
    <div class="h-full flex flex-col">
      <div class="flex items-center justify-between p-4 border-b border-base-300">
        <h2 class="text-lg font-bold">Navigation</h2>
        <.flyover_close_button id={@__flyover_id__} myself={@myself} />
      </div>

      <nav class="flex-1 overflow-auto p-4">
        <ul class="menu">
          <li><a href="/" class="text-base">Home</a></li>
          <li><a href="/demos" class="text-base">Demos</a></li>
          <li>
            <details open>
              <summary class="text-base font-medium">Forms</summary>
              <ul>
                <li><a href="/demos/checkout">Checkout</a></li>
                <li><a href="/demos/form-validation">Form Validation</a></li>
                <li><a href="/demos/bindings">Bindings</a></li>
              </ul>
            </details>
          </li>
          <li>
            <details open>
              <summary class="text-base font-medium">Data</summary>
              <ul>
                <li><a href="/demos/products">Products (URL)</a></li>
                <li><a href="/demos/products-socket">Products (Socket)</a></li>
                <li><a href="/demos/categories">Categories</a></li>
              </ul>
            </details>
          </li>
          <li>
            <details open>
              <summary class="text-base font-medium">Components</summary>
              <ul>
                <li><a href="/demos/counter">Counter</a></li>
                <li><a href="/demos/tags">Tag Editor</a></li>
                <li><a href="/demos/flyover">Flyover</a></li>
              </ul>
            </details>
          </li>
        </ul>
      </nav>

      <div class="p-4 border-t border-base-300">
        <p class="text-sm text-base-content/60">
          Lavash Flyover Demo
        </p>
      </div>
    </div>
    """
  end
end
