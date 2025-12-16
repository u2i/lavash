defmodule DemoWeb.ProductsLive do
  use Lavash.LiveView

  alias Demo.Catalog
  alias Demo.Catalog.Product

  # All filter state stored in URL - shareable, bookmarkable, back/forward works
  input :search, :string, from: :url, default: ""
  input :category, :string, from: :url, default: ""
  input :in_stock, :string, from: :url, default: ""  # "", "true", "false"
  input :min_price, :integer, from: :url, default: nil
  input :max_price, :integer, from: :url, default: nil
  input :min_rating, :integer, from: :url, default: nil

  # Modal state - ephemeral (not in URL)
  input :editing_product_id, :integer, from: :ephemeral, default: nil
  input :submitting, :boolean, from: :ephemeral, default: false

  # Load the product being edited (nil when modal closed)
  read :editing_product, Product do
    id input(:editing_product_id)
  end

  # Form for editing in modal
  form :edit_form, Product do
    data result(:editing_product)
  end

  # Products are derived from filter state
  derive :products do
    argument :search, input(:search)
    argument :category, input(:category)
    argument :in_stock, input(:in_stock)
    argument :min_price, input(:min_price)
    argument :max_price, input(:max_price)
    argument :min_rating, input(:min_rating)
    run fn filters, _ ->
      {:ok, products} = Catalog.list_products(
        filters.search,
        if(filters.category == "", do: nil, else: filters.category),
        parse_bool(filters.in_stock),
        filters.min_price,
        filters.max_price,
        filters.min_rating
      )
      products
    end
  end

  derive :categories do
    run fn _, _ ->
      {:ok, categories} = Catalog.list_categories()
      categories
    end
  end

  derive :result_count do
    argument :products, result(:products)
    run fn %{products: products}, _ ->
      length(products)
    end
  end

  derive :has_filters do
    argument :search, input(:search)
    argument :category, input(:category)
    argument :in_stock, input(:in_stock)
    argument :min_price, input(:min_price)
    argument :max_price, input(:max_price)
    argument :min_rating, input(:min_rating)
    run fn f, _ ->
      f.search != "" or f.category != "" or f.in_stock != "" or
      f.min_price != nil or f.max_price != nil or f.min_rating != nil
    end
  end

  actions do
    action :set_search, [:value] do
      set :search, & &1.params.value
    end

    action :set_category, [:value] do
      set :category, & &1.params.value
    end

    action :set_in_stock, [:value] do
      set :in_stock, & &1.params.value
    end

    action :set_min_price, [:value] do
      set :min_price, & parse_int(&1.params.value)
    end

    action :set_max_price, [:value] do
      set :max_price, & parse_int(&1.params.value)
    end

    action :set_min_rating, [:value] do
      set :min_rating, & parse_int(&1.params.value)
    end

    action :clear_filters do
      set :search, ""
      set :category, ""
      set :in_stock, ""
      set :min_price, nil
      set :max_price, nil
      set :min_rating, nil
    end

    # Modal actions
    action :open_edit, [:id] do
      set :editing_product_id, &parse_int(&1.params.id)
    end

    action :close_modal do
      set :editing_product_id, nil
      set :submitting, false
    end

    action :save_edit do
      set :submitting, true
      submit :edit_form, on_success: :save_success, on_error: :save_failed
      flash :info, "Product updated successfully!"
    end

    action :save_success do
      set :editing_product_id, nil
      set :submitting, false
    end

    action :save_failed do
      set :submitting, false
    end

    # No-op action to stop click propagation on modal content
    action :noop do
    end
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-6xl mx-auto p-6">
      <div class="flex items-center justify-between mb-6">
        <div>
          <h1 class="text-3xl font-bold">Product Catalog (URL State)</h1>
          <p class="text-gray-500 mt-1">Filter state stored in URL - try bookmarking or sharing</p>
        </div>
        <div class="flex gap-4">
          <a href="/products-socket" class="text-indigo-600 hover:text-indigo-800">Socket State Version</a>
          <a href="/" class="text-indigo-600 hover:text-indigo-800">&larr; Back to Counter</a>
        </div>
      </div>

      <div class="grid grid-cols-4 gap-6">
        <!-- Filters Sidebar -->
        <div class="col-span-1 bg-white rounded-lg shadow p-4 h-fit">
          <div class="flex items-center justify-between mb-4">
            <h2 class="font-semibold text-lg">Filters</h2>
            <button
              :if={@has_filters}
              phx-click="clear_filters"
              class="text-sm text-red-600 hover:text-red-800"
            >
              Clear all
            </button>
          </div>

          <div class="space-y-4">
            <!-- Search -->
            <div>
              <label class="block text-sm font-medium text-gray-700 mb-1">Search</label>
              <form phx-change="set_search">
                <input
                  type="text"
                  name="value"
                  value={@search}
                  placeholder="Search products..."
                  phx-debounce="300"
                  class="w-full px-3 py-2 border rounded-md text-sm"
                />
              </form>
            </div>

            <!-- Category -->
            <div>
              <label class="block text-sm font-medium text-gray-700 mb-1">Category</label>
              <form phx-change="set_category">
                <select name="value" class="w-full px-3 py-2 border rounded-md text-sm">
                  <option value="">All Categories</option>
                  <option :for={cat <- @categories} value={cat} selected={@category == cat}>
                    {cat}
                  </option>
                </select>
              </form>
            </div>

            <!-- In Stock -->
            <div>
              <label class="block text-sm font-medium text-gray-700 mb-1">Availability</label>
              <form phx-change="set_in_stock">
                <select name="value" class="w-full px-3 py-2 border rounded-md text-sm">
                  <option value="" selected={@in_stock == ""}>All</option>
                  <option value="true" selected={@in_stock == "true"}>In Stock</option>
                  <option value="false" selected={@in_stock == "false"}>Out of Stock</option>
                </select>
              </form>
            </div>

            <!-- Price Range -->
            <div>
              <label class="block text-sm font-medium text-gray-700 mb-1">Price Range</label>
              <div class="flex gap-2">
                <form phx-change="set_min_price" class="flex-1">
                  <input
                    type="number"
                    name="value"
                    value={@min_price}
                    placeholder="Min"
                    class="w-full px-3 py-2 border rounded-md text-sm"
                  />
                </form>
                <span class="self-center text-gray-400">-</span>
                <form phx-change="set_max_price" class="flex-1">
                  <input
                    type="number"
                    name="value"
                    value={@max_price}
                    placeholder="Max"
                    class="w-full px-3 py-2 border rounded-md text-sm"
                  />
                </form>
              </div>
            </div>

            <!-- Min Rating -->
            <div>
              <label class="block text-sm font-medium text-gray-700 mb-1">Minimum Rating</label>
              <form phx-change="set_min_rating">
                <select name="value" class="w-full px-3 py-2 border rounded-md text-sm">
                  <option value="" selected={@min_rating == nil}>Any Rating</option>
                  <option :for={r <- [4, 3, 2, 1]} value={r} selected={@min_rating == r}>
                    {r}+ stars
                  </option>
                </select>
              </form>
            </div>
          </div>

          <!-- Current URL display -->
          <div class="mt-6 pt-4 border-t">
            <p class="text-xs text-gray-400 mb-1">Current filter URL:</p>
            <code class="text-xs bg-gray-100 p-2 rounded block break-all">
              {build_url(assigns)}
            </code>
          </div>
        </div>

        <!-- Products Grid -->
        <div class="col-span-3">
          <div class="flex items-center justify-between mb-4">
            <p class="text-gray-600">
              Showing <span class="font-semibold">{@result_count}</span> products
            </p>
          </div>

          <div class="grid grid-cols-3 gap-4">
            <div
              :for={product <- @products}
              class="bg-white rounded-lg shadow p-4 hover:shadow-md transition-shadow"
            >
              <div class="flex items-start justify-between">
                <h3 class="font-medium text-gray-900">{product.name}</h3>
                <span class={[
                  "text-xs px-2 py-1 rounded-full",
                  product.in_stock && "bg-green-100 text-green-800",
                  !product.in_stock && "bg-red-100 text-red-800"
                ]}>
                  {if product.in_stock, do: "In Stock", else: "Out of Stock"}
                </span>
              </div>
              <p class="text-sm text-gray-500 mt-1">{product.category}</p>
              <div class="flex items-center justify-between mt-3">
                <span class="text-lg font-bold text-indigo-600">
                  ${Decimal.to_string(product.price)}
                </span>
                <span class="text-sm text-yellow-600">
                  {"★" |> String.duplicate(round(Decimal.to_float(product.rating)))}
                  <span class="text-gray-400 ml-1">{Decimal.to_string(product.rating)}</span>
                </span>
              </div>
              <button
                phx-click="open_edit"
                phx-value-id={product.id}
                class="mt-3 block w-full text-center text-sm text-indigo-600 hover:text-indigo-800 border-t pt-3"
              >
                Edit
              </button>
            </div>
          </div>

          <div :if={@result_count == 0} class="text-center py-12 bg-white rounded-lg shadow">
            <p class="text-gray-500 text-lg">No products match your filters</p>
            <button
              phx-click="clear_filters"
              class="mt-4 text-indigo-600 hover:text-indigo-800"
            >
              Clear all filters
            </button>
          </div>
        </div>
      </div>

      <!-- Edit Modal -->
      <div
        :if={@editing_product_id != nil}
        class="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50"
        id="modal-backdrop"
        phx-click-away="close_modal"
        phx-window-keydown="close_modal"
        phx-key="escape"
      >
        <div
          class="bg-white rounded-lg shadow-xl max-w-md w-full mx-4"
          phx-click="noop"
        >
          <%= cond do %>
            <% @editing_product == :loading -> %>
              <div class="p-6">
                <div class="animate-pulse">
                  <div class="h-6 bg-gray-200 rounded w-1/3 mb-4"></div>
                  <div class="h-10 bg-gray-200 rounded mb-4"></div>
                  <div class="h-10 bg-gray-200 rounded mb-4"></div>
                  <div class="h-10 bg-gray-200 rounded"></div>
                </div>
              </div>

            <% match?({:error, _}, @editing_product) -> %>
              <div class="p-6 text-center">
                <p class="text-red-600">Failed to load product</p>
                <button
                  phx-click="close_modal"
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
                    phx-click="close_modal"
                    class="text-gray-400 hover:text-gray-600"
                  >
                    &times;
                  </button>
                </div>

                <.form for={@edit_form} phx-change="validate" phx-submit="save_edit" class="space-y-4">
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
                      phx-click="close_modal"
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

  defp build_url(assigns) do
    params =
      %{}
      |> maybe_add("search", assigns.search, "")
      |> maybe_add("category", assigns.category, "")
      |> maybe_add("in_stock", assigns.in_stock, "")
      |> maybe_add("min_price", assigns.min_price, nil)
      |> maybe_add("max_price", assigns.max_price, nil)
      |> maybe_add("min_rating", assigns.min_rating, nil)

    if params == %{} do
      "/products"
    else
      "/products?" <> URI.encode_query(params)
    end
  end

  defp maybe_add(params, _key, value, default) when value == default, do: params
  defp maybe_add(params, key, value, _default), do: Map.put(params, key, value)

  defp parse_bool("true"), do: true
  defp parse_bool("false"), do: false
  defp parse_bool(_), do: nil

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil
  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> nil
    end
  end
  defp parse_int(val) when is_integer(val), do: val
end
