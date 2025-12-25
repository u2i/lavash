defmodule DemoWeb.Storefront.ProductsLive do
  use Lavash.LiveView
  import Lavash.LiveView.Helpers

  use Phoenix.VerifiedRoutes,
    endpoint: DemoWeb.Endpoint,
    router: DemoWeb.Router,
    statics: DemoWeb.static_paths()

  alias Demo.Catalog.{Product, Category}

  # URL state for filters - shareable, bookmarkable, optimistic
  state :roast, {:array, :string}, from: :url, default: [], optimistic: true
  state :category, {:array, :string}, from: :url, default: [], optimistic: true
  state :in_stock, :boolean, from: :url, default: false, optimistic: true

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
  end

  derive :has_filters do
    argument :roast, state(:roast)
    argument :category, state(:category)
    argument :in_stock, state(:in_stock)

    run fn args, _ ->
      args.roast != [] or args.category != [] or args.in_stock
    end
  end

  # Derive chip classes for roast levels
  derive :roast_chips do
    optimistic true
    argument :roast, state(:roast)

    run fn %{roast: selected}, _ ->
      levels = ["light", "medium", "medium_dark", "dark"]
      Map.new(levels, fn level -> {level, chip_class(level in selected)} end)
    end
  end

  # Derive chip classes for categories
  derive :category_chips do
    optimistic true
    argument :category, state(:category)
    argument :categories, result(:categories)

    run fn %{category: selected, categories: cats}, _ ->
      Map.new(cats, fn cat -> {cat.slug, chip_class(cat.slug in selected)} end)
    end
  end

  # Derive chip class for in_stock toggle
  derive :in_stock_chip do
    optimistic true
    argument :in_stock, state(:in_stock)

    run fn %{in_stock: active}, _ ->
      chip_class(active)
    end
  end

  defp chip_class(active) do
    base = "px-3 py-1.5 text-sm rounded-full border transition-colors cursor-pointer"

    if active do
      "#{base} bg-primary text-primary-content border-primary"
    else
      "#{base} bg-base-100 text-base-content/70 border-base-300 hover:border-primary/50"
    end
  end

  defp to_atoms(list) when is_list(list) do
    Enum.map(list, &String.to_existing_atom/1)
  end

  defp to_atoms(_), do: []

  actions do
    action :toggle_roast, [:val] do
      set :roast, &toggle_in_list(&1.state.roast, &1.params.val)
    end

    action :toggle_category, [:val] do
      set :category, &toggle_in_list(&1.state.category, &1.params.val)
    end

    action :toggle_in_stock do
      set :in_stock, &(not &1.state.in_stock)
    end

    action :clear_filters do
      set :roast, []
      set :category, []
      set :in_stock, false
    end
  end

  defp toggle_in_list(list, value) when value in ["", nil] do
    # Ignore empty/nil values
    list
  end

  defp toggle_in_list(list, value) do
    if value in list do
      List.delete(list, value)
    else
      [value | list]
    end
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

  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="text-center py-4">
        <h1 class="text-3xl font-bold">Our Coffees</h1>
        <p class="text-base-content/70 mt-2">Freshly roasted, ethically sourced</p>
      </div>

      <!-- Filters -->
      <div class="card bg-base-200 p-4">
        <div class="flex flex-wrap gap-6">
          <!-- Roast Level Filter -->
          <div>
            <h3 class="text-sm font-semibold text-base-content/60 mb-2">Roast Level</h3>
            <div class="flex flex-wrap gap-2">
              <button class={@roast_chips["light"]} phx-click="toggle_roast" phx-value-val="light"
                      data-optimistic="toggle_roast" data-optimistic-value="light" data-optimistic-class="roast_chips.light">
                Light
              </button>
              <button class={@roast_chips["medium"]} phx-click="toggle_roast" phx-value-val="medium"
                      data-optimistic="toggle_roast" data-optimistic-value="medium" data-optimistic-class="roast_chips.medium">
                Medium
              </button>
              <button class={@roast_chips["medium_dark"]} phx-click="toggle_roast" phx-value-val="medium_dark"
                      data-optimistic="toggle_roast" data-optimistic-value="medium_dark" data-optimistic-class="roast_chips.medium_dark">
                Med-Dark
              </button>
              <button class={@roast_chips["dark"]} phx-click="toggle_roast" phx-value-val="dark"
                      data-optimistic="toggle_roast" data-optimistic-value="dark" data-optimistic-class="roast_chips.dark">
                Dark
              </button>
            </div>
          </div>

          <!-- Category Filter -->
          <div>
            <h3 class="text-sm font-semibold text-base-content/60 mb-2">Category</h3>
            <div class="flex flex-wrap gap-2">
              <%= for cat <- @categories do %>
                <button class={@category_chips[cat.slug]} phx-click="toggle_category" phx-value-val={cat.slug}
                        data-optimistic="toggle_category" data-optimistic-value={cat.slug} data-optimistic-class={"category_chips.#{cat.slug}"}>
                  {cat.name}
                </button>
              <% end %>
            </div>
          </div>

          <!-- In Stock Filter -->
          <div>
            <h3 class="text-sm font-semibold text-base-content/60 mb-2">Availability</h3>
            <div class="flex flex-wrap gap-2">
              <button class={@in_stock_chip} phx-click="toggle_in_stock"
                      data-optimistic="toggle_in_stock" data-optimistic-class="in_stock_chip">
                In Stock Only
              </button>
            </div>
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
          <a href={~p"/products/#{product.id}"} class="card bg-base-200 hover:shadow-lg transition-all hover:-translate-y-1">
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
                <span class="text-amber-500 text-sm">{"★" |> String.duplicate(round(Decimal.to_float(product.rating)))}</span>
                <span class="text-xs text-base-content/50">{Decimal.to_string(product.rating)}</span>
              </div>

              <div class="card-actions justify-between items-center mt-4 pt-4 border-t border-base-300">
                <div>
                  <span class="text-lg font-bold">${Decimal.to_string(product.price)}</span>
                  <span class="text-xs text-base-content/50">/ {product.weight_oz}oz</span>
                </div>
                <%= if product.in_stock do %>
                  <span class="btn btn-sm btn-primary">Add to Cart</span>
                <% else %>
                  <span class="btn btn-sm btn-disabled">Sold Out</span>
                <% end %>
              </div>
            </div>
          </a>
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

      <script :type={Phoenix.LiveView.ColocatedJS} name="optimistic">
        // Client-side optimistic functions for filter chips

        const CHIP_BASE = "px-3 py-1.5 text-sm rounded-full border transition-colors cursor-pointer";
        const CHIP_ACTIVE = CHIP_BASE + " bg-primary text-primary-content border-primary";
        const CHIP_INACTIVE = CHIP_BASE + " bg-base-100 text-base-content/70 border-base-300 hover:border-primary/50";

        function chipClass(active) {
          return active ? CHIP_ACTIVE : CHIP_INACTIVE;
        }

        function toggleInList(list, value) {
          if (!value) return list;
          const arr = list || [];
          const idx = arr.indexOf(value);
          if (idx >= 0) {
            return arr.filter(v => v !== value);
          } else {
            return [...arr, value];
          }
        }

        export default {
          // Actions
          toggle_roast(state, value) {
            return { roast: toggleInList(state.roast, value) };
          },

          toggle_category(state, value) {
            return { category: toggleInList(state.category, value) };
          },

          toggle_in_stock(state) {
            return { in_stock: !state.in_stock };
          },

          // Derives
          roast_chips(state) {
            const levels = ["light", "medium", "medium_dark", "dark"];
            const result = {};
            for (const level of levels) {
              result[level] = chipClass((state.roast || []).includes(level));
            }
            return result;
          },

          category_chips(state) {
            // Use category_slugs from initial render data if available
            const slugs = state._category_slugs || [];
            const result = {};
            for (const slug of slugs) {
              result[slug] = chipClass((state.category || []).includes(slug));
            }
            return result;
          },

          in_stock_chip(state) {
            return chipClass(state.in_stock);
          }
        };
      </script>
    </div>
    """
  end
end
