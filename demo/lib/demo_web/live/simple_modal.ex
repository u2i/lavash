defmodule DemoWeb.SimpleModal do
  @moduledoc """
  A simple modal component for testing modal behavior with async loading.

  This modal demonstrates the loading skeleton pattern without using forms:
  1. Click opens modal immediately (optimistic)
  2. Loading skeleton shows while async data loads
  3. Content fades in when data arrives

  Opening the modal from client-side:
  - JS.dispatch("open-panel", to: "#simple-modal-modal", detail: %{open: true})
  """
  use Lavash.Component, extensions: [Lavash.Overlay.Modal.Dsl]

  import Lavash.Overlay.Modal.Helpers, only: [modal_close_button: 1]

  alias Demo.Catalog.Product

  # Configure modal behavior with async loading
  modal do
    open_field :open
    async_assign :product
    max_width :md
  end

  # Load a random product to display (simulates async data)
  read :product, Product do
    id fn _state -> Demo.Catalog.Product |> Ash.Query.limit(1) |> Ash.read_one!() |> then(& &1.id) end
  end

  render_loading fn assigns ->
    ~L"""
    <div class="p-6">
      <div class="animate-pulse">
        <div class="h-6 bg-gray-200 rounded w-1/3 mb-6"></div>
        <div class="space-y-3">
          <div class="h-4 bg-gray-200 rounded w-full"></div>
          <div class="h-4 bg-gray-200 rounded w-5/6"></div>
          <div class="h-4 bg-gray-200 rounded w-4/6"></div>
        </div>
        <div class="mt-6 pt-4 border-t">
          <div class="h-10 bg-gray-200 rounded"></div>
        </div>
      </div>
    </div>
    """
  end

  render fn assigns ->
    ~L"""
    <div class="p-6">
      <div class="flex items-center justify-between mb-6">
        <h2 class="text-xl font-bold">Product Details</h2>
        <.modal_close_button id={@__modal_id__} myself={@myself} />
      </div>

      <div class="space-y-4">
        <div class="bg-gray-50 rounded-lg p-4">
          <h3 class="font-semibold text-lg">{@product.name}</h3>
          <p class="text-gray-600 mt-1">${Decimal.to_string(@product.price)}</p>
        </div>

        <div class="bg-blue-50 border border-blue-200 rounded-lg p-4">
          <p class="text-sm text-blue-800">
            This content was loaded asynchronously after the modal opened.
          </p>
        </div>

        <div class="bg-gray-100 rounded-lg p-4">
          <h3 class="font-semibold mb-2">Test Instructions</h3>
          <ol class="list-decimal list-inside space-y-1 text-sm text-gray-600">
            <li>Click to open - modal appears immediately</li>
            <li>Loading skeleton shows while data loads</li>
            <li>Content fades in when data arrives</li>
            <li>Close and reopen to test again</li>
          </ol>
        </div>

        <div class="flex gap-3 pt-4 border-t">
          <button
            type="button"
            phx-click={Phoenix.LiveView.JS.dispatch("close-panel", to: "#simple-modal-modal")}
            class="btn btn-primary flex-1"
          >
            Close Modal
          </button>
        </div>
      </div>
    </div>
    """
  end
end
