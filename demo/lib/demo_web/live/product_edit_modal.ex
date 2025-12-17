defmodule DemoWeb.ProductEditModal do
  @moduledoc """
  A Lavash Component for editing a product in a modal.

  Uses the Lavash.Modal plugin for modal behavior:
  - product_id controls open state (nil = closed)
  - :close and :noop actions are auto-injected
  - modal chrome, wrapper, and async_result are auto-generated

  Parent invokes actions to control the modal:
  - invoke "product-edit-modal", :open, module: DemoWeb.ProductEditModal, params: [product_id: 123]

  ## Example usage

      <.lavash_component
        module={DemoWeb.ProductEditModal}
        id="product-edit-modal"
      />
  """
  use Lavash.Component, extensions: [Lavash.Modal.Dsl]

  alias DemoWeb.CoreComponents
  import Lavash.Modal.Helpers, only: [modal_close_button: 1]

  alias Demo.Catalog.Product

  # Configure modal behavior
  modal do
    open_field :product_id
    async_assign :edit_form
  end

  render_loading fn assigns ->
    ~H"""
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
    ~H"""
    <div class="p-6">
      <div class="flex items-center justify-between mb-4">
        <h2 class="text-xl font-bold">Edit Product</h2>
        <.modal_close_button myself={@myself} />
      </div>

      <.form for={@form} phx-change="validate" phx-submit="save" phx-target={@myself}>
        <CoreComponents.input field={@form[:name]} label="Name" />
        <CoreComponents.input field={@form[:category]} label="Category" />
        <CoreComponents.input field={@form[:price]} type="number" label="Price" step="0.01" />
        <CoreComponents.input field={@form[:rating]} type="number" label="Rating" step="0.1" min="0" max="5" />
        <CoreComponents.input field={@form[:in_stock]} type="checkbox" label="In Stock" />

        <div class="flex gap-3 pt-4 border-t">
          <CoreComponents.button type="submit" phx-disable-with="Saving..." class="flex-1 btn-primary">
            Save Changes
          </CoreComponents.button>
          <CoreComponents.button type="button" phx-click="close" phx-target={@myself} class="btn-outline">
            Cancel
          </CoreComponents.button>
        </div>
      </.form>
    </div>
    """
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
    action :open, [:product_id] do
      set :product_id, &(&1.params.product_id)
    end

    action :save do
      submit :edit_form, on_success: :close
    end
  end

end
