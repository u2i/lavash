defmodule DemoWeb.LiveViewDemos.ProductsLive do
  @moduledoc """
  Product catalog with URL-backed filters — the non-DSL counterpart
  to `DemoWeb.ProductsLive`.

  Everything the DSL does declaratively is wired by hand here:

  - URL state: filter events `push_patch` to self; `handle_params`
    feeds the URL into the graph (`Reactive.put` + `recompute`)
  - Async read: `:products` is an `async: true` derive running the
    same Ash `:list` read; while re-querying, the `AsyncResult`
    keeps the previous rows so the grid dims instead of blanking
  - PubSub invalidation: mount subscribes to the resource topic;
    on `{:lavash_invalidate, ...}` the derive is marked dirty and
    recomputed (edit a product in /admin to see it)

  Uses the raw `Lavash.Reactive` builder API (`new/state/derive/build`)
  rather than `defgraph`, to show the no-macro path.
  """
  use DemoWeb, :live_view
  import Lavash.Rx

  alias Demo.Catalog.{Category, Product}
  alias Lavash.Reactive

  defp graph do
    Reactive.graph(__MODULE__, fn ->
      Reactive.new()
      |> Reactive.state(:search, "")
      |> Reactive.state(:category_id, nil)
      |> Reactive.state(:in_stock, nil)
      |> Reactive.derive(:products, rx(fetch_products(@search, @category_id, @in_stock)),
        async: true,
        tags: [{:resource, Product}]
      )
      |> Reactive.derive(:result_count, rx(length(@products)))
      |> Reactive.derive(
        :has_filters,
        rx(@search != "" or @category_id != nil or @in_stock != nil)
      )
      |> Reactive.build()
    end)
  end

  def mount(_params, _session, socket) do
    if connected?(socket), do: Lavash.PubSub.subscribe(Product)

    categories =
      Category
      |> Ash.Query.sort(:name)
      |> Ash.read!()
      |> Enum.map(&{&1.name, &1.id})

    socket =
      socket
      |> Reactive.init(graph())
      |> assign(:category_options, categories)

    {:ok, socket}
  end

  # URL is the source of truth: params flow into the graph here, and
  # only the fields that actually changed trigger recomputation.
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> Reactive.put(:search, params["search"] || "")
      |> Reactive.put(:category_id, presence(params["category_id"]))
      |> Reactive.put(:in_stock, parse_bool(params["in_stock"]))
      |> Reactive.recompute()

    {:noreply, socket}
  end

  # Filter events don't mutate state directly — they navigate, and
  # handle_params applies the change. Back/forward and bookmarks work.
  def handle_event("set_search", %{"value" => value}, socket) do
    {:noreply, patch_filters(socket, %{search: value})}
  end

  def handle_event("set_category", %{"value" => value}, socket) do
    {:noreply, patch_filters(socket, %{category_id: value})}
  end

  def handle_event("set_in_stock", %{"value" => value}, socket) do
    {:noreply, patch_filters(socket, %{in_stock: value})}
  end

  def handle_event("clear_filters", _, socket) do
    {:noreply, push_patch(socket, to: "/lv/products")}
  end

  # Any product mutation (e.g. an /admin edit) lands here via the
  # resource topic — mark the read dirty and recompute. This is what
  # `invalidate :pubsub` on a DSL `read` does under the hood.
  def handle_info({:lavash_invalidate, Product}, socket) do
    {:noreply, refetch_products(socket)}
  end

  def handle_info({:lavash_invalidate, Product, _detail}, socket) do
    {:noreply, refetch_products(socket)}
  end

  # Async derive results
  def handle_info(msg, socket) do
    case Reactive.handle_async(socket, msg) do
      {:ok, socket} -> {:noreply, socket}
      :not_handled -> {:noreply, socket}
    end
  end

  defp refetch_products(socket) do
    socket
    |> Lavash.Socket.mark_dirty([:products])
    |> Reactive.recompute()
  end

  defp patch_filters(socket, changes) do
    filters =
      %{
        search: socket.assigns.search,
        category_id: socket.assigns.category_id,
        in_stock: socket.assigns.in_stock
      }
      |> Map.merge(changes)
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)

    push_patch(socket, to: "/lv/products?" <> URI.encode_query(filters))
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value), do: value

  defp parse_bool("true"), do: true
  defp parse_bool("false"), do: false
  defp parse_bool(_), do: nil

  # Public: called from the :products rx() derive (rx compute
  # functions are compiled outside the module's private scope).
  def fetch_products(search, category_id, in_stock) do
    Product
    |> Ash.Query.for_read(:list, %{
      search: presence(search),
      category_id: category_id,
      in_stock: in_stock
    })
    |> Ash.read!()
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-6xl mx-auto p-6">
      <div class="flex items-center justify-between mb-6">
        <div>
          <h1 class="text-3xl font-bold">Products (Reactive, URL State)</h1>
          <p class="text-base-content/60 mt-1">
            Hand-wired handle_params + async derive + PubSub — no DSL
          </p>
        </div>
        <div class="flex gap-4">
          <a href="/demos/products" class="link">DSL version</a>
          <a href="/lv" class="link">&larr; LiveView demos</a>
        </div>
      </div>

      <div class="grid grid-cols-4 gap-6">
        <!-- Filters -->
        <div class="col-span-1 card bg-base-100 shadow p-4 h-fit">
          <div class="flex items-center justify-between mb-4">
            <h2 class="font-semibold text-lg">Filters</h2>
            <button
              :if={@has_filters}
              phx-click="clear_filters"
              class="btn btn-ghost btn-xs text-error"
            >
              Clear all
            </button>
          </div>

          <div class="space-y-4">
            <div>
              <label class="block text-sm font-medium mb-1">Search</label>
              <form phx-change="set_search">
                <input
                  type="text"
                  name="value"
                  value={@search}
                  placeholder="Search products..."
                  phx-debounce="300"
                  class="input input-bordered input-sm w-full"
                />
              </form>
            </div>

            <div>
              <label class="block text-sm font-medium mb-1">Category</label>
              <form phx-change="set_category">
                <select name="value" class="select select-bordered select-sm w-full">
                  <option value="">All categories</option>
                  <option
                    :for={{name, id} <- @category_options}
                    value={id}
                    selected={@category_id == id}
                  >
                    {name}
                  </option>
                </select>
              </form>
            </div>

            <div>
              <label class="block text-sm font-medium mb-1">Availability</label>
              <form phx-change="set_in_stock">
                <select name="value" class="select select-bordered select-sm w-full">
                  <option value="">All</option>
                  <option value="true" selected={@in_stock == true}>In stock</option>
                  <option value="false" selected={@in_stock == false}>Out of stock</option>
                </select>
              </form>
            </div>
          </div>
        </div>

        <!-- Results -->
        <div class="col-span-3">
          <%= case @products do %>
            <% %Phoenix.LiveView.AsyncResult{loading: loading, result: rows} when loading != nil -> %>
              <div class="relative">
                <div :if={rows} class="opacity-40 pointer-events-none">
                  <.product_grid products={rows} />
                </div>
                <div class="absolute inset-0 flex items-start justify-center pt-16">
                  <span class="loading loading-spinner loading-lg text-primary"></span>
                </div>
                <div :if={!rows} class="h-40"></div>
              </div>
            <% %Phoenix.LiveView.AsyncResult{ok?: true, result: rows} -> %>
              <div class="mb-3 text-sm text-base-content/60">
                {unwrap(@result_count)} products
              </div>
              <.product_grid products={rows} />
            <% %Phoenix.LiveView.AsyncResult{failed: failed} when failed != nil -> %>
              <div class="alert alert-error">Failed to load products.</div>
            <% _ -> %>
              <div class="h-40"></div>
          <% end %>
        </div>
      </div>

      <div class="mt-8 p-4 bg-base-200 rounded-lg max-w-2xl">
        <h3 class="font-semibold mb-2">How it works</h3>
        <ul class="text-sm text-base-content/70 space-y-1">
          <li>
            &bull; Filter events <code class="bg-base-300 px-1 rounded">push_patch</code>
            to self; <code class="bg-base-300 px-1 rounded">handle_params</code>
            puts URL values into the graph
          </li>
          <li>
            &bull; <code class="bg-base-300 px-1 rounded">:products</code>
            is an async derive running the Ash <code class="bg-base-300 px-1 rounded">:list</code>
            read — previous rows stay visible (dimmed) while re-querying
          </li>
          <li>
            &bull; <code class="bg-base-300 px-1 rounded">Lavash.PubSub.subscribe(Product)</code>
            + marking the derive dirty = live updates when /admin edits a product
          </li>
        </ul>
      </div>
    </div>
    """
  end

  defp product_grid(assigns) do
    ~H"""
    <div class="grid md:grid-cols-3 gap-4">
      <div :for={product <- @products} class="card bg-base-100 shadow">
        <div class="card-body py-4">
          <h3 class="card-title text-base">{product.name}</h3>
          <p class="text-sm text-base-content/60">${Decimal.to_string(product.price)}</p>
          <div class="flex items-center gap-2 text-xs">
            <span class={[
              "badge badge-sm",
              if(product.in_stock, do: "badge-success", else: "badge-ghost")
            ]}>
              {if product.in_stock, do: "in stock", else: "out of stock"}
            </span>
            <span :if={product.rating} class="text-base-content/50">
              &#9733; {product.rating}
            </span>
          </div>
        </div>
      </div>
      <p :if={@products == []} class="col-span-3 text-center text-base-content/50 py-12">
        No products match these filters.
      </p>
    </div>
    """
  end

  defp unwrap(%Phoenix.LiveView.AsyncResult{ok?: true, result: result}), do: result
  defp unwrap(%Phoenix.LiveView.AsyncResult{}), do: "…"
  defp unwrap(other), do: other
end
