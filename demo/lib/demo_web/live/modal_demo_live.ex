defmodule DemoWeb.ModalDemoLive do
  @moduledoc """
  Demo page for the Modal component.

  Shows how to use the Lavash.Overlay.Modal.Dsl extension to create
  modals with optimistic open/close animations.
  """
  use Lavash.LiveView
  import Lavash.LiveView.Helpers

  render fn assigns ->
    ~L"""
    <div class="max-w-4xl mx-auto p-6">
      <div class="flex items-center justify-between mb-6">
        <div>
          <h1 class="text-3xl font-bold">Modal Demo</h1>
          <p class="text-gray-500 mt-1">Basic modal with optimistic animations</p>
        </div>
        <a href="/demos" class="text-indigo-600 hover:text-indigo-800">&larr; All Demos</a>
      </div>

      <div class="bg-white rounded-lg shadow p-6 mb-8">
        <h2 class="font-semibold text-lg mb-4">Simple Modal</h2>
        <p class="text-gray-600 mb-4">Click the button to open a basic modal. The modal opens optimistically (immediately) without waiting for the server.</p>
        <button
          class="btn btn-primary"
          phx-click={Phoenix.LiveView.JS.dispatch("open-panel", to: "#simple-modal-modal", detail: %{open: true})}
        >
          Open Modal
        </button>
      </div>

      <div class="bg-white rounded-lg shadow p-6 mb-8">
        <h2 class="font-semibold text-lg mb-4">Features</h2>
        <ul class="list-disc list-inside space-y-2 text-gray-600">
          <li><strong>Optimistic Open:</strong> Modal appears immediately on click</li>
          <li><strong>Smooth Animations:</strong> Fade and scale transitions</li>
          <li><strong>Backdrop:</strong> Click outside to close</li>
          <li><strong>Escape Key:</strong> Press ESC to close</li>
        </ul>
      </div>

      <!-- Simple Modal Component -->
      <.lavash_component
        module={DemoWeb.SimpleModal}
        id="simple-modal"
      />
    </div>
    """
  end
end
