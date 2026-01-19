defmodule DemoWeb.CategoriesLive do
  use Lavash.LiveView
  import Lavash.LiveView.Helpers

  alias Demo.Catalog.Category

  # All categories
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

  render fn assigns ->
    ~H"""
    <div class="max-w-4xl mx-auto p-6">
      <div class="flex items-center justify-between mb-6">
        <div>
          <h1 class="text-3xl font-bold">Categories</h1>
          <p class="text-gray-500 mt-1">Manage product categories</p>
        </div>
        <div class="flex gap-4">
          <button
            phx-click="open_new"
            class="bg-indigo-600 text-white px-4 py-2 rounded-md hover:bg-indigo-700"
          >
            New Category
          </button>
          <a href="/products" class="text-indigo-600 hover:text-indigo-800 self-center">
            &larr; Back to Products
          </a>
        </div>
      </div>

      <!-- Categories List -->
      <div class="bg-white rounded-lg shadow">
        <table class="min-w-full divide-y divide-gray-200">
          <thead class="bg-gray-50">
            <tr>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Name
              </th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Slug
              </th>
              <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                Actions
              </th>
            </tr>
          </thead>
          <tbody class="bg-white divide-y divide-gray-200">
            <tr :for={category <- @categories} class="hover:bg-gray-50">
              <td class="px-6 py-4 whitespace-nowrap text-sm font-medium text-gray-900">
                {category.name}
              </td>
              <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                {category.slug}
              </td>
              <td class="px-6 py-4 whitespace-nowrap text-right text-sm font-medium">
                <button
                  phx-click="open_edit"
                  phx-value-id={category.id}
                  class="btn btn-ghost btn-xs text-primary"
                >
                  Edit
                </button>
                <button
                  phx-click="delete"
                  phx-value-id={category.id}
                  data-confirm="Are you sure you want to delete this category?"
                  class="btn btn-ghost btn-xs text-error"
                >
                  Delete
                </button>
              </td>
            </tr>
            <tr :if={@categories == []} class="text-center">
              <td colspan="3" class="px-6 py-12 text-gray-500">
                No categories yet. Create one to get started.
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <.lavash_component
        module={DemoWeb.CategoryEditModal}
        id="category-edit-modal"
      />
    </div>
    """
  end
end
