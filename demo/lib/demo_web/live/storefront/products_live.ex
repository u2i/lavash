defmodule DemoWeb.Storefront.ProductsLive do
  use Lavash.LiveView
  import Lavash.LiveView.Helpers

  use Phoenix.VerifiedRoutes,
    endpoint: DemoWeb.Endpoint,
    router: DemoWeb.Router,
    statics: DemoWeb.static_paths()

  alias Demo.Cart.Cart
  alias Demo.Catalog.{Category, Product}

  # ============================================
  # Filter State
  # ============================================

  # Filter state — ChipSet/ToggleChip components handle the UX,
  # parent just owns the selected values as plain state fields
  state :roast, {:array, :string}, from: :url, default: [], optimistic: true
  state :category, {:array, :string}, from: :url, default: [], optimistic: true
  state :in_stock, :boolean, from: :url, default: false, optimistic: true
  state :search, :string, from: :url, default: "", optimistic: true, setter: true
  state :sort, :atom, from: :url, default: :name, optimistic: true, setter: true

  # ============================================
  # Cart State
  # ============================================

  # Cart ID loaded/created on mount
  state :cart_id, :string, from: :ephemeral

  # Injected by the auth on_mount hook; lifted into lavash state so
  # the template can pass it to the store_page top bar.
  state :current_user, :map, from: :assigns, assigns_key: :current_user

  # Parent owns flyover open state, bound down to CartFlyover
  state :cart_open, :any, from: :ephemeral, default: nil, optimistic: true

  # ============================================
  # Reads
  # ============================================

  # Load categories for filter chips
  read :categories, Category do
    async false
  end

  # Load products using Ash :storefront action - auto-maps state to action arguments
  read :products, Product, :storefront do
    async false
    # Map state fields to action arguments with transforms
    argument :roast, state(:roast), transform: &to_atoms/1
    argument :category_slugs, state(:category)
    argument :in_stock, state(:in_stock)
    argument :search, state(:search)
    argument :sort, state(:sort)
  end

  # The cart itself is fully owned by DemoWeb.CartFlyover (trigger +
  # badge + panel) — this page only knows the cart_id.

  # ============================================
  # Calculations & Derives
  # ============================================

  calculate :has_filters,
            rx(@roast != [] or @category != [] or @in_stock or @search != ""),
            optimistic: false

  defp to_atoms(list) when is_list(list) do
    Enum.map(list, &String.to_existing_atom/1)
  end

  defp to_atoms(_), do: []

  actions do
    action :clear_filters do
      set :roast, []
      set :category, []
      set :in_stock, false
      set :search, ""
    end

    # Add to cart: opens the flyover optimistically and invokes the
    # flyover's :add_item. The product's display fields ride along
    # (from phx-value-* on the card button) so the flyover's upsert
    # can predict a COMPLETE row either way — an existing product's
    # quantity ticks, a new one appears — badge, row, and totals all
    # move before the server replies (`:create_row` snapshots the
    # authoritative price).
    action :add_to_cart, [:product_id, :name, :origin, :unit_price] do
      set :cart_open, true

      invoke "cart-flyover", :add_item,
        module: DemoWeb.CartFlyover,
        params: [
          product_id: {:param, :product_id},
          qty: 1,
          name: {:param, :name},
          origin: {:param, :origin},
          unit_price: {:param, :unit_price}
        ]
    end
  end

  mount do
    run fn socket -> find_or_create_cart(socket) end
  end

  defp find_or_create_cart(socket) do
    user = socket.assigns[:current_user]

    cart_id =
      if user do
        case Cart |> Ash.Query.for_read(:for_user, %{user_id: user.id}) |> Ash.read_one() do
          {:ok, nil} ->
            {:ok, cart} =
              Cart
              |> Ash.Changeset.for_create(:create, %{}, actor: user)
              |> Ash.create()

            cart.id

          {:ok, cart} ->
            cart.id

          _ ->
            nil
        end
      else
        nil
      end

    Lavash.Socket.put_state(socket, :cart_id, cart_id)
  end

  defp coffee_image(roast_level) do
    case roast_level do
      :light -> "photo-1495474472287-4d71bcdd2085"
      :medium -> "photo-1559056199-641a0ac8b55e"
      :medium_dark -> "photo-1509042239860-f550ce710b93"
      :dark -> "photo-1514432324607-a09d9b4aefdd"
      _ -> "photo-1447933601403-0c6688de566e"
    end
  end

  defp roast_badge(level) do
    case level do
      :light -> {"bg-amber-100 text-amber-800", "Light"}
      :medium -> {"bg-orange-100 text-orange-800", "Medium"}
      :medium_dark -> {"bg-orange-200 text-orange-900", "Med-Dark"}
      :dark -> {"bg-stone-700 text-stone-100", "Dark"}
      _ -> {"bg-base-300 text-base-content", "Unknown"}
    end
  end

  template do
    ~H"""
    <DemoWeb.Layouts.store_page current_user={@current_user}>
      <:cart>
        <%!-- Cart: trigger (icon + optimistic badge) AND flyover panel,
             all owned by the component — the store_page top bar just
             places it. --%>
        <.lavash_component
          module={DemoWeb.CartFlyover}
          id="cart-flyover"
          cart_id={@cart_id}
          open={@cart_open}
          bind={[open: :cart_open]}
        />
      </:cart>
      <div class="space-y-6">
        <div class="text-center">
          <h1 class="text-3xl font-bold">Our Coffees</h1>
          <p class="text-base-content/70 mt-2">Freshly roasted, ethically sourced</p>
        </div>

        <!-- Search + sort row -->
        <div class="flex flex-col md:flex-row gap-3">
          <form phx-change="set_search" class="flex-1">
            <input
              type="text"
              name="value"
              value={@search}
              data-lavash-bind="search"
              placeholder="Search coffees..."
              autocomplete="off"
              class="input input-bordered w-full"
            />
          </form>
          <form phx-change="set_sort">
            <select
              name="value"
              data-lavash-bind="sort"
              class="select select-bordered w-full md:w-auto"
            >
              <option value="name" selected={@sort == :name}>Name (A-Z)</option>
              <option value="price_asc" selected={@sort == :price_asc}>Price: low to high</option>
              <option value="price_desc" selected={@sort == :price_desc}>Price: high to low</option>
              <option value="rating_desc" selected={@sort == :rating_desc}>Rating</option>
            </select>
          </form>
        </div>

        <!-- Filters -->
        <div class="card bg-base-200 p-4">
          <div class="flex flex-wrap gap-6">
            <!-- Roast Level Filter -->
            <div>
              <h3 class="text-sm font-semibold text-base-content/60 mb-2">Roast Level</h3>
              <.lavash_component
                module={Lavash.ChipSet}
                id="roast-chips"
                values={["light", "medium", "medium_dark", "dark"]}
                labels={%{"medium_dark" => "Med-Dark"}}
                selected={@roast}
                bind={[selected: :roast]}
              />
            </div>

            <!-- Category Filter (dynamic values from read) -->
            <div>
              <h3 class="text-sm font-semibold text-base-content/60 mb-2">Category</h3>
              <.lavash_component
                module={Lavash.ChipSet}
                id="category-chips"
                values={Enum.map(@categories, & &1.slug)}
                labels={Map.new(@categories, &{&1.slug, &1.name})}
                selected={@category}
                bind={[selected: :category]}
              />
            </div>

            <!-- In Stock Filter (boolean toggle) -->
            <div>
              <h3 class="text-sm font-semibold text-base-content/60 mb-2">Availability</h3>
              <.lavash_component
                module={Lavash.ToggleChip}
                id="in-stock-toggle"
                label="In Stock Only"
                active={@in_stock}
                bind={[active: :in_stock]}
              />
            </div>
          </div>

          <!-- Active filters summary & clear -->
          <%= if @has_filters do %>
            <div class="mt-4 pt-4 border-t border-base-300 flex items-center justify-between">
              <p class="text-sm text-base-content/60">
                Showing {length(@products)} {if length(@products) == 1, do: "coffee", else: "coffees"}
              </p>
              <button phx-click="clear_filters" class="btn btn-ghost btn-sm">
                Clear all filters
              </button>
            </div>
          <% end %>
        </div>

        <!-- Product Grid -->
        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
          <%= for product <- @products do %>
            <% {badge_color, badge_label} = roast_badge(product.roast_level) %>
            <div
              class="card bg-base-200 hover:shadow-lg transition-all hover:-translate-y-1 cursor-pointer"
              phx-click={Phoenix.LiveView.JS.navigate(~p"/storefront/products/#{product.id}")}
            >
              <figure class="px-4 pt-4">
                <img
                  src={"https://images.unsplash.com/#{coffee_image(product.roast_level)}?w=400&q=80"}
                  alt={product.name}
                  class="w-full h-40 object-cover rounded-lg"
                />
              </figure>
              <div class="card-body pt-4">
                <div class="flex justify-between items-start">
                  <div>
                    <h2 class="card-title text-lg">{product.name}</h2>
                    <p class="text-sm text-base-content/60">{product.origin}</p>
                  </div>
                  <span class={"text-xs px-2 py-1 rounded-full font-medium #{badge_color}"}>
                    {badge_label}
                  </span>
                </div>

                <p class="text-sm text-base-content/70 mt-2 line-clamp-2">
                  {product.tasting_notes}
                </p>

                <div class="flex items-center gap-1 mt-2">
                  <span class="text-amber-500 text-sm">{"★"
                  |> String.duplicate(round(Decimal.to_float(product.rating)))}</span>
                  <span class="text-xs text-base-content/50">{Decimal.to_string(product.rating)}</span>
                </div>

                <div class="card-actions justify-between items-center mt-4 pt-4 border-t border-base-300">
                  <div>
                    <span class="text-lg font-bold">${Decimal.to_string(product.price)}</span>
                    <span class="text-xs text-base-content/50">/ {product.weight_oz}oz</span>
                  </div>
                  <%= if product.in_stock do %>
                    <button
                      type="button"
                      class="btn btn-sm btn-primary"
                      phx-click="add_to_cart"
                      phx-value-product_id={product.id}
                      phx-value-name={product.name}
                      phx-value-origin={product.origin}
                      phx-value-unit_price={Decimal.to_string(product.price)}
                    >
                      Add to Cart
                    </button>
                  <% else %>
                    <span class="btn btn-sm btn-disabled">Sold Out</span>
                  <% end %>
                </div>
              </div>
            </div>
          <% end %>
        </div>

        <%= if @products == [] do %>
          <div class="text-center py-12 text-base-content/50">
            <p>No coffees match your filters.</p>
            <button phx-click="clear_filters" class="btn btn-ghost btn-sm mt-4">
              Clear filters
            </button>
          </div>
        <% end %>
      </div>
    </DemoWeb.Layouts.store_page>
    """
  end
end
