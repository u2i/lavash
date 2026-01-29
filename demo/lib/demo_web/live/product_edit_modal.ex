defmodule DemoWeb.ProductEditModal do
  @moduledoc """
  A Lavash Component for editing a product in a modal.

  Uses the Lavash.Modal plugin for modal behavior:
  - product_id controls open state (nil = closed)
  - set_product_id action is auto-generated (optimistic: true implies setter: true)
  - modal chrome, wrapper, and async_result are auto-generated

  Opening the modal from client-side:
  - JS.dispatch("open-panel", to: "#product-edit-modal-modal", detail: %{product_id: 123})

  ## Example usage

      <.lavash_component
        module={DemoWeb.ProductEditModal}
        id="product-edit-modal"
      />
  """
  use Lavash.Component, extensions: [Lavash.Overlay.Modal.Dsl]

  alias DemoWeb.CoreComponents
  import Lavash.Overlay.Modal.Helpers, only: [modal_close_button: 1]

  alias Demo.Catalog.{Category, Product}

  # Configure modal behavior
  modal do
    open_field :product_id
    async_assign :edit_form
  end

  render_loading fn assigns ->
    ~L"""
    <div class="p-6">
      <div class="animate-pulse">
        <div class="h-6 bg-gray-200 rounded w-1/3 mb-4"></div>
        <div class="h-10 bg-gray-200 rounded mb-4"></div>
        <div class="h-10 bg-gray-200 rounded mb-4"></div>
        <div class="h-10 bg-gray-200 rounded"></div>
      </div>
    </div>
    """
  end

  render fn assigns ->
    ~L"""
    <div class="p-6">
      <div class="flex items-center justify-between mb-4">
        <h2 class="text-xl font-bold">Edit Product</h2>
        <.modal_close_button id={@__modal_id__} myself={@myself} />
      </div>

      <.form for={@form} phx-change="validate" phx-submit="save" phx-target={@myself}>
        <CoreComponents.input field={@form[:name]} label="Name" />
        <CoreComponents.input
          field={@form[:category_id]}
          type="select"
          label="Category"
          options={@category_options}
          prompt="Select category..."
        />
        <CoreComponents.input field={@form[:price]} type="number" label="Price" step="0.01" />
        <CoreComponents.input
          field={@form[:rating]}
          type="number"
          label="Rating"
          step="0.1"
          min="0"
          max="5"
        />
        <CoreComponents.input field={@form[:in_stock]} type="checkbox" label="In Stock" />

        <div class="flex gap-3 pt-4 border-t">
          <CoreComponents.button
            type="submit"
            data-lavash-enabled="edit_form_valid"
            phx-disable-with="Saving..."
            class="flex-1 btn-primary"
          >
            Save Changes
          </CoreComponents.button>
          <CoreComponents.button
            type="button"
            phx-click={Phoenix.LiveView.JS.dispatch("close-panel", to: "#product-edit-modal-modal")}
            class="btn-outline"
          >
            Cancel
          </CoreComponents.button>
        </div>
      </.form>
    </div>
    """
  end

  # Load categories for the dropdown
  read :category_options, Category do
    async false
    as_options label: :name, value: :id
  end

  # Load the product when product_id is set
  read :product, Product do
    id state(:product_id)
  end

  # Form for editing
  form :edit_form, Product do
    data result(:product)
  end

  actions do
    # set_product_id is auto-generated because the modal's open_field (product_id)
    # has optimistic: true, which implies setter: true

    action :save do
      submit :edit_form, on_success: :close
    end
  end
end
