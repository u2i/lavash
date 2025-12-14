defmodule DemoWeb.ProductEditLive do
  @moduledoc """
  Demo: Form handling with Lavash using the imperative API and Ash changesets.

  This demonstrates how to handle forms where:
  - The product is loaded async based on URL param
  - Form data is stored in ephemeral state
  - Ash changeset is derived from product + form_data
  - Submission uses handle_event with async operation and branching
  """
  use Lavash.LiveView

  alias Demo.Catalog

  state do
    url do
      field :product_id, :integer
    end

    ephemeral do
      field :form_data, :map, default: %{}
      field :submitting, :boolean, default: false
    end
  end

  derived do
    # Load the product async based on product_id
    # Returns {:ok, product} or {:error, reason} - errors propagate automatically
    field :product, depends_on: [:product_id], async: true, compute: fn %{product_id: id} ->
      case id do
        nil -> {:error, :no_id}
        id -> Catalog.get_product(id)
      end
    end

    # Ash changeset is derived from product + form_data
    # Only runs when product is ready (not :loading or {:error, _})
    field :changeset, depends_on: [:product, :form_data], compute: fn
      %{product: product, form_data: form_data} ->
        Catalog.change_product(product, form_data)
    end

    # Form struct using AshPhoenix.Form
    # Only runs when changeset is ready
    field :form, depends_on: [:changeset], compute: fn %{changeset: changeset} ->
      changeset.data
      |> AshPhoenix.Form.for_update(:update,
        params: changeset.params || %{},
        errors: changeset.errors != []
      )
      |> Phoenix.Component.to_form()
    end
  end

  assigns do
    assign :product_id
    assign :product
    assign :form
    assign :submitting
  end

  # Validation on change - uses declarative action since no async/branching needed
  actions do
    action :validate, [:product] do
      set :form_data, fn %{params: params} ->
        # params.product is the form data under the "product" key
        params.product || %{}
      end
    end
  end

  # Submission uses handle_event because we need:
  # 1. To read fresh changeset after setting form_data
  # 2. Async database operation
  # 3. Branch on result (navigate vs show errors)
  def handle_event("save", %{"form" => params}, socket) do
    # Set form_data and submitting state
    socket =
      socket
      |> Lavash.set(:form_data, params)
      |> Lavash.set(:submitting, true)
      |> Lavash.finalize(__MODULE__)

    # Now get the fresh form (recomputed with new form_data)
    form = Lavash.get(socket, :form)

    case AshPhoenix.Form.submit(form) do
      {:ok, _product} ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(:info, "Product updated successfully!")
          |> Phoenix.LiveView.push_navigate(to: "/products")

        {:noreply, socket}

      {:error, form} ->
        # Store the form with errors - we need to update form_data to trigger recompute
        # but the errors come from the form submission
        socket =
          socket
          |> Lavash.set(:submitting, false)
          |> Lavash.finalize(__MODULE__)

        # For now, just show the error state
        {:noreply, socket}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto p-6">
      <div class="flex items-center justify-between mb-6">
        <div>
          <h1 class="text-3xl font-bold">Edit Product</h1>
          <p class="text-gray-500 mt-1">Form handling with Lavash + Ash changesets</p>
        </div>
        <a href="/products" class="text-indigo-600 hover:text-indigo-800">&larr; Back to Products</a>
      </div>

      <%= case @product do %>
        <% :loading -> %>
          <div class="bg-white rounded-lg shadow p-6">
            <div class="animate-pulse">
              <div class="h-4 bg-gray-200 rounded w-1/4 mb-4"></div>
              <div class="h-10 bg-gray-200 rounded mb-4"></div>
              <div class="h-4 bg-gray-200 rounded w-1/4 mb-4"></div>
              <div class="h-10 bg-gray-200 rounded mb-4"></div>
            </div>
          </div>

        <% {:error, _reason} -> %>
          <div class="bg-white rounded-lg shadow p-6 text-center">
            <p class="text-gray-500 text-lg">Product not found</p>
            <a href="/products" class="mt-4 inline-block text-indigo-600 hover:text-indigo-800">
              Back to Products
            </a>
          </div>

        <% {:ok, _product} when is_struct(@form, Phoenix.HTML.Form) -> %>
          <div class="bg-white rounded-lg shadow p-6">
            <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-4">
              <div>
                <label class="block text-sm font-medium text-gray-700 mb-1">Name</label>
                <input
                  type="text"
                  name={@form[:name].name}
                  value={@form[:name].value}
                  class={[
                    "w-full px-3 py-2 border rounded-md",
                    @form[:name].errors != [] && "border-red-500"
                  ]}
                />
                <.error :for={error <- @form[:name].errors}>{translate_error(error)}</.error>
              </div>

              <div>
                <label class="block text-sm font-medium text-gray-700 mb-1">Category</label>
                <input
                  type="text"
                  name={@form[:category].name}
                  value={@form[:category].value}
                  class={[
                    "w-full px-3 py-2 border rounded-md",
                    @form[:category].errors != [] && "border-red-500"
                  ]}
                />
                <.error :for={error <- @form[:category].errors}>{translate_error(error)}</.error>
              </div>

              <div>
                <label class="block text-sm font-medium text-gray-700 mb-1">Price</label>
                <input
                  type="number"
                  step="0.01"
                  name={@form[:price].name}
                  value={@form[:price].value}
                  class={[
                    "w-full px-3 py-2 border rounded-md",
                    @form[:price].errors != [] && "border-red-500"
                  ]}
                />
                <.error :for={error <- @form[:price].errors}>{translate_error(error)}</.error>
              </div>

              <div>
                <label class="block text-sm font-medium text-gray-700 mb-1">Rating</label>
                <input
                  type="number"
                  step="0.1"
                  min="0"
                  max="5"
                  name={@form[:rating].name}
                  value={@form[:rating].value}
                  class="w-full px-3 py-2 border rounded-md"
                />
              </div>

              <div class="flex items-center gap-2">
                <input
                  type="checkbox"
                  name={@form[:in_stock].name}
                  value="true"
                  checked={@form[:in_stock].value == true}
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
                  {if @submitting, do: "Saving...", else: "Save Changes"}
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

        <% _ -> %>
          <!-- Fallback: product loaded but form not ready yet -->
          <div class="bg-white rounded-lg shadow p-6">
            <div class="animate-pulse">
              <div class="h-4 bg-gray-200 rounded w-1/4 mb-4"></div>
              <div class="h-10 bg-gray-200 rounded mb-4"></div>
              <div class="h-4 bg-gray-200 rounded w-1/4 mb-4"></div>
              <div class="h-10 bg-gray-200 rounded mb-4"></div>
            </div>
          </div>
      <% end %>
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
