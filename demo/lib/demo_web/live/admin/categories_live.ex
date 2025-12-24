defmodule DemoWeb.Admin.CategoriesLive do
  use Lavash.LiveView
  import Lavash.LiveView.Helpers

  alias Demo.Catalog.Category

  read :categories, Category do
    async false
  end

  actions do
    action :open_edit, [:id] do
      invoke "category-edit-modal", :open,
        module: DemoWeb.CategoryEditModal,
        params: [category_id: {:param, :id}]
    end

    action :open_new do
      invoke "category-edit-modal", :open,
        module: DemoWeb.CategoryEditModal,
        params: [category_id: nil]
    end

    action :delete, [:id] do
      effect fn %{params: %{id: id}} ->
        Category
        |> Ash.get!(id)
        |> Ash.destroy!()
      end
    end
  end

  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-bold">Categories</h1>
        <button phx-click="open_new" class="btn btn-primary">
          New Category
        </button>
      </div>

      <div class="overflow-x-auto">
        <table class="table table-zebra">
          <thead>
            <tr>
              <th>Name</th>
              <th>Slug</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={category <- @categories}>
              <td class="font-medium">{category.name}</td>
              <td class="text-base-content/70">{category.slug}</td>
              <td class="text-right">
                <button phx-click="open_edit" phx-value-id={category.id} class="btn btn-ghost btn-sm">
                  Edit
                </button>
                <button
                  phx-click="delete"
                  phx-value-id={category.id}
                  data-confirm="Are you sure you want to delete this category?"
                  class="btn btn-ghost btn-sm text-error"
                >
                  Delete
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div :if={@categories == []} class="text-center py-12 text-base-content/50">
        <p>No categories yet. Create one to get started.</p>
      </div>

      <.lavash_component module={DemoWeb.CategoryEditModal} id="category-edit-modal" />
    </div>
    """
  end
end
