defmodule DemoWeb.CategoryEditModal do
  @moduledoc """
  A Lavash Component for editing/creating a category in a modal.
  """
  use Lavash.Component, extensions: [Lavash.Overlay.Modal.Dsl]

  alias DemoWeb.CoreComponents
  import Lavash.Overlay.Modal.Helpers, only: [modal_close_button: 1]

  alias Demo.Catalog.Category

  # Configure modal behavior
  modal do
    open_field :category_id
    async_assign :form
  end

  render_loading fn assigns ->
    ~L"""
    <div class="p-6">
      <div class="animate-pulse">
        <div class="h-6 bg-gray-200 rounded w-1/3 mb-4"></div>
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
        <h2 class="text-xl font-bold">
          {if @form_action == :create, do: "New Category", else: "Edit Category"}
        </h2>
        <.modal_close_button id={@__modal_id__} myself={@myself} />
      </div>

      <.form for={@form} phx-change="validate" phx-submit="save" phx-target={@myself}>
        <CoreComponents.input field={@form[:name]} label="Name" placeholder="Category name" />
        <CoreComponents.input field={@form[:slug]} label="Slug" placeholder="category-slug" />

        <div class="flex gap-3 pt-4 border-t">
          <CoreComponents.button type="submit" phx-disable-with="Saving..." class="flex-1 btn-primary">
            Save
          </CoreComponents.button>
          <CoreComponents.button
            type="button"
            phx-click={@on_close}
            class="btn-outline"
          >
            Cancel
          </CoreComponents.button>
        </div>
      </.form>
    </div>
    """
  end

  # Load the category when category_id is set (nil for new)
  read :category, Category do
    id state(:category_id)
  end

  # Form for editing/creating
  form :form, Category do
    data result(:category)
  end

  actions do
    action :open, [:category_id] do
      set :category_id, & &1.params.category_id
    end

    action :save do
      submit :form, on_success: :close
    end
  end
end
