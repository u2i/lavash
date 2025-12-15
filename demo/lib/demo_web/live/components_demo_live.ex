defmodule DemoWeb.ComponentsDemoLive do
  @moduledoc """
  Demo page showcasing Lavash.Component with ProductCard.

  Demonstrates:
  - Component socket state (expanded) survives reconnects
  - Component ephemeral state (hovered) lost on reconnect
  - Derived state (show_details) from both
  """
  use Lavash.LiveView
  import Lavash.LiveView.Helpers

  alias Demo.Catalog
  alias DemoWeb.ProductCard

  # Derive products (computed once on mount - no arguments)
  derive :products do
    run fn _, _ ->
      Catalog.list_products(%{}) |> Enum.take(6)
    end
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-6xl mx-auto p-6">
      <div class="flex items-center justify-between mb-6">
        <div>
          <h1 class="text-3xl font-bold">Lavash Components Demo</h1>
          <p class="text-gray-500 mt-1">ProductCard with socket state (expanded) and ephemeral state (hovered)</p>
        </div>
        <div class="flex gap-4">
          <a href="/products-socket" class="text-indigo-600 hover:text-indigo-800">Socket LiveView</a>
          <a href="/products" class="text-indigo-600 hover:text-indigo-800">URL LiveView</a>
          <a href="/" class="text-indigo-600 hover:text-indigo-800">&larr; Counter</a>
        </div>
      </div>

      <!-- Info banner -->
      <div class="mb-6 p-4 bg-blue-50 border border-blue-200 rounded-lg">
        <p class="text-blue-800 text-sm">
          <strong>Component State Demo:</strong> Click cards to expand them (socket state - survives reconnect).
          Hover over cards to see details (ephemeral state - lost on reconnect).
          Try expanding some cards, then simulate a reconnect - expanded state persists, but hover state resets.
        </p>
      </div>

      <div class="grid grid-cols-3 gap-4">
        <.lavash_component
          :for={product <- @products}
          module={ProductCard}
          id={"product-#{product.id}"}
          product={product}
        />
      </div>

      <div class="mt-8 p-4 bg-gray-50 rounded-lg">
        <h2 class="font-semibold mb-2">How it works:</h2>
        <ul class="text-sm text-gray-600 space-y-1">
          <li><strong>Props:</strong> <code>product</code> - passed from parent LiveView</li>
          <li><strong>Socket state:</strong> <code>expanded</code> - survives reconnects (synced to JS client by component ID)</li>
          <li><strong>Ephemeral state:</strong> <code>hovered</code> - lost on reconnect</li>
          <li><strong>Derived:</strong> <code>show_details</code> - true if expanded OR hovered</li>
        </ul>
      </div>
    </div>
    """
  end
end
