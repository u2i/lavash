defmodule DemoWeb.ProductEditModal do
  @moduledoc """
  A Lavash Component for editing a product in a modal.

  The component fully owns its state:
  - product_id: which product to edit (nil = closed)
  - Loads the product when product_id changes
  - Manages the edit form internally
  - Handles form validation and submission

  Parent invokes actions to control the modal:
  - invoke "product-edit-modal", :open, module: DemoWeb.ProductEditModal, params: [product_id: 123]

  ## Example usage

      <.lavash_component
        module={DemoWeb.ProductEditModal}
        id="product-edit-modal"
      />

  The modal is opened by the parent invoking the :open action with a product_id.
  The modal closes itself when the user clicks close or after successful save.
  """
  use Lavash.Component

  alias Demo.Catalog.Product

  # Component owns its state - no props needed
  input :product_id, :integer, from: :ephemeral, default: nil
  input :submitting, :boolean, from: :ephemeral, default: false

  # Load the product when product_id is set
  read :product, Product do
    id input(:product_id)
  end

  # Form for editing
  form :edit_form, Product do
    data result(:product)
  end

  actions do
    action :noop do
    end

    # Invokable by parent to open the modal
    action :open, [:product_id] do
      set :product_id, &(&1.params.product_id)
    end

    action :close do
      set :product_id, nil
    end

    action :save do
      set :submitting, true
      submit :edit_form, on_success: :save_success, on_error: :save_failed
    end

    action :save_success do
      set :submitting, false
      set :product_id, nil
    end

    action :save_failed do
      set :submitting, false
    end
  end

  def render(assigns) do
    ~H"""
    <div id={@id}>
      <div
        :if={@product_id != nil}
        class="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50"
        id="modal-backdrop"
        phx-click="close"
        phx-target={@myself}
        phx-window-keydown="close"
        phx-key="escape"
      >
        <div
          class="bg-white rounded-lg shadow-xl max-w-md w-full mx-4"
          phx-click="noop"
          phx-target={@myself}
        >
          <.async_result :let={form} assign={@edit_form}>
            <:loading>
              <div class="p-6">
                <div class="animate-pulse">
                  <div class="h-6 bg-gray-200 rounded w-1/3 mb-4"></div>
                  <div class="h-10 bg-gray-200 rounded mb-4"></div>
                  <div class="h-10 bg-gray-200 rounded mb-4"></div>
                  <div class="h-10 bg-gray-200 rounded"></div>
                </div>
              </div>
            </:loading>
            <div class="p-6">
              <div class="flex items-center justify-between mb-4">
                <h2 class="text-xl font-bold">Edit Product</h2>
                <button
                  phx-click="close"
                  phx-target={@myself}
                  class="text-gray-400 hover:text-gray-600"
                >
                  &times;
                </button>
              </div>

              <.form for={form} phx-change="validate" phx-submit="save" phx-target={@myself} class="space-y-4">
                <div>
                  <label class="block text-sm font-medium text-gray-700 mb-1">Name</label>
                  <input
                    type="text"
                    name={form[:name].name}
                    value={form[:name].value}
                    class={[
                      "w-full px-3 py-2 border rounded-md",
                      form[:name].errors != [] && "border-red-500"
                    ]}
                  />
                  <.field_error :for={error <- form[:name].errors}>{translate_error(error)}</.field_error>
                </div>

                <div>
                  <label class="block text-sm font-medium text-gray-700 mb-1">Category</label>
                  <input
                    type="text"
                    name={form[:category].name}
                    value={form[:category].value}
                    class={[
                      "w-full px-3 py-2 border rounded-md",
                      form[:category].errors != [] && "border-red-500"
                    ]}
                  />
                  <.field_error :for={error <- form[:category].errors}>{translate_error(error)}</.field_error>
                </div>

                <div>
                  <label class="block text-sm font-medium text-gray-700 mb-1">Price</label>
                  <input
                    type="number"
                    step="0.01"
                    name={form[:price].name}
                    value={form[:price].value}
                    class={[
                      "w-full px-3 py-2 border rounded-md",
                      form[:price].errors != [] && "border-red-500"
                    ]}
                  />
                  <.field_error :for={error <- form[:price].errors}>{translate_error(error)}</.field_error>
                </div>

                <div>
                  <label class="block text-sm font-medium text-gray-700 mb-1">Rating</label>
                  <input
                    type="number"
                    step="0.1"
                    min="0"
                    max="5"
                    name={form[:rating].name}
                    value={form[:rating].value}
                    class="w-full px-3 py-2 border rounded-md"
                  />
                </div>

                <div class="flex items-center gap-2">
                  <input
                    type="checkbox"
                    name={form[:in_stock].name}
                    value="true"
                    checked={form[:in_stock].value == true}
                    class="rounded border-gray-300"
                  />
                  <label class="text-sm font-medium text-gray-700">In Stock</label>
                </div>

                <div class="flex gap-3 pt-4 border-t">
                  <button
                    type="submit"
                    disabled={@submitting}
                    class={[
                      "flex-1 px-4 py-2 rounded-md text-white font-medium",
                      @submitting && "bg-gray-400 cursor-not-allowed",
                      !@submitting && "bg-indigo-600 hover:bg-indigo-700"
                    ]}
                  >
                    {if @submitting, do: "Saving...", else: "Save Changes"}
                  </button>
                  <button
                    type="button"
                    phx-click="close"
                    phx-target={@myself}
                    class="px-4 py-2 rounded-md border border-gray-300 text-gray-700 hover:bg-gray-50"
                  >
                    Cancel
                  </button>
                </div>
              </.form>
            </div>
          </.async_result>
        </div>
      </div>
    </div>
    """
  end

  defp field_error(assigns) do
    ~H"""
    <p class="text-red-600 text-sm mt-1">{render_slot(@inner_block)}</p>
    """
  end

  defp translate_error({msg, opts}) when is_list(opts) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  defp translate_error({msg, _opts}), do: to_string(msg)
  defp translate_error(msg) when is_binary(msg), do: msg
end
