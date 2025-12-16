defmodule DemoWeb.ProductEditModal do
  @moduledoc """
  A Lavash Component for editing a product in a modal.

  The component manages its own state:
  - Loads the product when product_id changes
  - Manages the edit form internally
  - Handles form validation and submission

  Props:
    - product_id: integer | nil - the product ID to edit (nil = closed)
    - on_close: string - event name to send to parent when closing
    - on_saved: string - event name to send to parent after successful save
  """
  use Lavash.Component

  alias Demo.Catalog.Product

  # Props from parent
  prop :product_id, :integer
  prop :on_close, :string, required: true
  prop :on_saved, :string, required: true

  # Internal state
  input :submitting, :boolean, from: :ephemeral, default: false

  # Load the product when product_id is set
  read :product, Product do
    id prop(:product_id)
  end

  # Form for editing
  form :edit_form, Product do
    data result(:product)
  end

  actions do
    action :noop do
    end

    action :save do
      set :submitting, true
      submit :edit_form, on_success: :save_success, on_error: :save_failed
    end

    action :save_success do
      set :submitting, false
      notify_parent :on_saved
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
        phx-click={@on_close}
        phx-window-keydown={@on_close}
        phx-key="escape"
      >
        <div
          class="bg-white rounded-lg shadow-xl max-w-md w-full mx-4"
          phx-click="noop"
          phx-target={@myself}
        >
          <%= cond do %>
            <% @product == :loading -> %>
              <div class="p-6">
                <div class="animate-pulse">
                  <div class="h-6 bg-gray-200 rounded w-1/3 mb-4"></div>
                  <div class="h-10 bg-gray-200 rounded mb-4"></div>
                  <div class="h-10 bg-gray-200 rounded mb-4"></div>
                  <div class="h-10 bg-gray-200 rounded"></div>
                </div>
              </div>

            <% match?({:error, _}, @product) -> %>
              <div class="p-6 text-center">
                <p class="text-red-600">Failed to load product</p>
                <button
                  phx-click={@on_close}
                  class="mt-4 text-gray-600 hover:text-gray-800"
                >
                  Close
                </button>
              </div>

            <% is_struct(@edit_form, Phoenix.HTML.Form) -> %>
              <div class="p-6">
                <div class="flex items-center justify-between mb-4">
                  <h2 class="text-xl font-bold">Edit Product</h2>
                  <button
                    phx-click={@on_close}
                    class="text-gray-400 hover:text-gray-600"
                  >
                    &times;
                  </button>
                </div>

                <.form for={@edit_form} phx-change="validate" phx-submit="save" phx-target={@myself} class="space-y-4">
                  <div>
                    <label class="block text-sm font-medium text-gray-700 mb-1">Name</label>
                    <input
                      type="text"
                      name={@edit_form[:name].name}
                      value={@edit_form[:name].value}
                      class={[
                        "w-full px-3 py-2 border rounded-md",
                        @edit_form[:name].errors != [] && "border-red-500"
                      ]}
                    />
                    <.field_error :for={error <- @edit_form[:name].errors}>{translate_error(error)}</.field_error>
                  </div>

                  <div>
                    <label class="block text-sm font-medium text-gray-700 mb-1">Category</label>
                    <input
                      type="text"
                      name={@edit_form[:category].name}
                      value={@edit_form[:category].value}
                      class={[
                        "w-full px-3 py-2 border rounded-md",
                        @edit_form[:category].errors != [] && "border-red-500"
                      ]}
                    />
                    <.field_error :for={error <- @edit_form[:category].errors}>{translate_error(error)}</.field_error>
                  </div>

                  <div>
                    <label class="block text-sm font-medium text-gray-700 mb-1">Price</label>
                    <input
                      type="number"
                      step="0.01"
                      name={@edit_form[:price].name}
                      value={@edit_form[:price].value}
                      class={[
                        "w-full px-3 py-2 border rounded-md",
                        @edit_form[:price].errors != [] && "border-red-500"
                      ]}
                    />
                    <.field_error :for={error <- @edit_form[:price].errors}>{translate_error(error)}</.field_error>
                  </div>

                  <div>
                    <label class="block text-sm font-medium text-gray-700 mb-1">Rating</label>
                    <input
                      type="number"
                      step="0.1"
                      min="0"
                      max="5"
                      name={@edit_form[:rating].name}
                      value={@edit_form[:rating].value}
                      class="w-full px-3 py-2 border rounded-md"
                    />
                  </div>

                  <div class="flex items-center gap-2">
                    <input
                      type="checkbox"
                      name={@edit_form[:in_stock].name}
                      value="true"
                      checked={@edit_form[:in_stock].value == true}
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
                      phx-click={@on_close}
                      class="px-4 py-2 rounded-md border border-gray-300 text-gray-700 hover:bg-gray-50"
                    >
                      Cancel
                    </button>
                  </div>
                </.form>
              </div>

            <% true -> %>
              <div class="p-6">
                <div class="animate-pulse">
                  <div class="h-6 bg-gray-200 rounded w-1/3 mb-4"></div>
                  <div class="h-10 bg-gray-200 rounded mb-4"></div>
                </div>
              </div>
          <% end %>
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
