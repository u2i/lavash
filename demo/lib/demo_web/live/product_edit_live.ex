defmodule DemoWeb.ProductEditLive do
  @moduledoc """
  Demo: Form handling with Lavash using declarative actions.

  This demonstrates how to handle forms where:
  - The product is loaded async based on URL param (nil for new)
  - Form is declared with the `form` DSL which handles create vs update
  - Submission is declarative with on_error branching to another action
  """
  use Lavash.LiveView

  alias Demo.Catalog.Product

  # State - mutable state from external sources
  state :product_id, :integer, from: :url
  state :submitting, :boolean, from: :ephemeral, default: false

  # Read - async load the product by ID
  read :product, Product do
    id state(:product_id)
  end

  # Form - creates AshPhoenix.Form, auto-detects create vs update
  # Also auto-projects @form_action (:create or :update) for UI
  # Params are implicit: :form_params is auto-created and bound to phx-change events
  form :form, Product do
    data result(:product)
  end

  # Declarative form submission with error handling
  actions do
    action :save do
      set :submitting, true
      submit :form, on_error: :save_failed
      flash :info, "Product saved successfully!"
      navigate "/products"
    end

    action :save_failed do
      set :submitting, false
    end
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto p-6">
      <div class="flex items-center justify-between mb-6">
        <div>
          <h1 class="text-3xl font-bold">{if @form_action == :create, do: "New Product", else: "Edit Product"}</h1>
          <p class="text-gray-500 mt-1">Form handling with Lavash + Ash changesets</p>
        </div>
        <a href="/products" class="text-indigo-600 hover:text-indigo-800">&larr; Back to Products</a>
      </div>

      <.async_result :let={form} assign={@form}>
        <:loading>
          <div class="bg-white rounded-lg shadow p-6">
            <div class="animate-pulse">
              <div class="h-4 bg-gray-200 rounded w-1/4 mb-4"></div>
              <div class="h-10 bg-gray-200 rounded mb-4"></div>
              <div class="h-4 bg-gray-200 rounded w-1/4 mb-4"></div>
              <div class="h-10 bg-gray-200 rounded mb-4"></div>
            </div>
          </div>
        </:loading>
        <:failed :let={_reason}>
          <div class="bg-white rounded-lg shadow p-6 text-center">
            <p class="text-gray-500 text-lg">Product not found</p>
            <a href="/products" class="mt-4 inline-block text-indigo-600 hover:text-indigo-800">
              Back to Products
            </a>
          </div>
        </:failed>
        <div class="bg-white rounded-lg shadow p-6">
          <.form for={form} phx-change="validate" phx-submit="save" class="space-y-4">
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
              <.error :for={error <- form[:name].errors}>{translate_error(error)}</.error>
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
              <.error :for={error <- form[:category].errors}>{translate_error(error)}</.error>
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
              <.error :for={error <- form[:price].errors}>{translate_error(error)}</.error>
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

            <div class="flex gap-4 pt-4">
              <button
                type="submit"
                disabled={@submitting}
                class={[
                  "px-4 py-2 rounded-md text-white font-medium",
                  @submitting && "bg-gray-400 cursor-not-allowed",
                  !@submitting && "bg-indigo-600 hover:bg-indigo-700"
                ]}
              >
                {cond do
                  @submitting -> "Saving..."
                  @form_action == :create -> "Create Product"
                  true -> "Save Changes"
                end}
              </button>
              <a
                href="/products"
                class="px-4 py-2 rounded-md border border-gray-300 text-gray-700 hover:bg-gray-50"
              >
                Cancel
              </a>
            </div>
          </.form>
        </div>

        <!-- Debug info -->
        <div class="mt-6 bg-gray-100 rounded-lg p-4">
          <h3 class="font-medium mb-2">State Debug</h3>
          <dl class="text-sm space-y-1">
            <div class="flex gap-2">
              <dt class="text-gray-500">product_id:</dt>
              <dd class="font-mono">{@product_id}</dd>
            </div>
            <div class="flex gap-2">
              <dt class="text-gray-500">submitting:</dt>
              <dd class="font-mono">{@submitting}</dd>
            </div>
          </dl>
        </div>
      </.async_result>
    </div>
    """
  end

  defp translate_error({msg, opts}) when is_list(opts) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  defp translate_error({msg, _opts}) do
    to_string(msg)
  end

  defp translate_error(msg) when is_binary(msg), do: msg

  defp error(assigns) do
    ~H"""
    <p class="text-red-600 text-sm mt-1">{render_slot(@inner_block)}</p>
    """
  end
end
