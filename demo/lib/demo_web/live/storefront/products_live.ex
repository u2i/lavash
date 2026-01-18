defmodule DemoWeb.Storefront.ProductsLive do
  use Lavash.LiveView
  import Lavash.LiveView.Helpers

  use Phoenix.VerifiedRoutes,
    endpoint: DemoWeb.Endpoint,
    router: DemoWeb.Router,
    statics: DemoWeb.static_paths()

  alias Demo.Catalog.{Product, Category}
  alias Demo.Cart.{Cart, CartItem}

  # ============================================
  # Filter State
  # ============================================

  # Static multi-select: roast levels are known at compile time
  # This auto-generates: state, toggle action, and chip derive
  multi_select :roast, ["light", "medium", "medium_dark", "dark"],
    from: :url,
    labels: %{"medium_dark" => "Med-Dark"}

  # Dynamic multi-select: category values come from a read
  # We use explicit state + action + derive since values are runtime-dependent
  state :category, {:array, :string}, from: :url, default: [], optimistic: true

  # Boolean toggle for in_stock filter
  # This auto-generates: state, toggle action, and chip derive
  toggle :in_stock, from: :url

  # ============================================
  # Cart State
  # ============================================

  # Cart ID loaded/created on mount
  state :cart_id, :string, from: :ephemeral

  # Note: Cart flyover manages its own open/close state internally.
  # We open it via JS.dispatch("open-panel", to: "#cart-flyover-flyover", detail: %{open: true})

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
  end

  # Load cart items with product preloaded (depends on cart_id)
  # Uses PubSub invalidation - auto-refreshes when cart items change
  read :cart_items, CartItem, :for_cart do
    argument :cart_id, state(:cart_id)
    async false
    invalidate :pubsub
  end

  # ============================================
  # Calculations & Derives
  # ============================================

  calculate :has_filters, rx(@roast != [] or @category != [] or @in_stock), optimistic: false

  # Transform cart items to JSON-serializable maps for ClientComponent
  calculate :cart_items_json, rx(serialize_cart_items(@cart_items)), optimistic: false

  def serialize_cart_items(items) do
    Enum.map(items || [], fn item ->
      %{
        id: item.id,
        quantity: item.quantity,
        unit_price: Decimal.to_string(item.unit_price),
        product: %{
          id: item.product.id,
          name: item.product.name,
          origin: item.product.origin,
          roast_level: to_string(item.product.roast_level)
        }
      }
    end)
  end

  # Cart calculations
  calculate :cart_item_count, rx(Enum.reduce(@cart_items, 0, fn item, acc -> acc + item.quantity end))

  calculate :cart_subtotal,
            rx(
              Enum.reduce(@cart_items, Decimal.new(0), fn item, acc ->
                Decimal.add(acc, Decimal.mult(item.unit_price, item.quantity))
              end)
            ),
            optimistic: false

  # String version of subtotal for JSON serialization
  calculate :cart_subtotal_str, rx(compute_subtotal_str(@cart_items)), optimistic: false

  def compute_subtotal_str(items) do
    subtotal =
      Enum.reduce(items || [], Decimal.new(0), fn item, acc ->
        Decimal.add(acc, Decimal.mult(item.unit_price, item.quantity))
      end)

    Decimal.to_string(subtotal)
  end

  # Chip classes for categories (dynamic values require explicit calculation)
  calculate :category_chips, rx(compute_category_chips(@category, @categories)), optimistic: false

  def compute_category_chips(selected, cats) do
    Map.new(cats, fn cat -> {cat.slug, chip_class(cat.slug in selected)} end)
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
    # Toggle action for dynamic category values
    action :toggle_category, [:val] do
      set :category, &toggle_in_list(&1.state.category, &1.params.val)
    end

    action :clear_filters do
      set :roast, []
      set :category, []
      set :in_stock, false
    end

    # Cart actions - use set to capture params, then effect to mutate + broadcast
    action :add_to_cart, [:product_id] do
      # Store product_id in ephemeral state for access in effect
      set :_pending_product_id, & &1.params.product_id

      effect fn state ->
        cart_id = state.cart_id
        product_id = state[:_pending_product_id]

        # Check if product already in cart
        existing =
          state.cart_items
          |> Enum.find(fn item -> item.product_id == product_id end)

        if existing do
          existing
          |> Ash.Changeset.for_update(:update_quantity, %{quantity: existing.quantity + 1})
          |> Ash.update!()
        else
          CartItem
          |> Ash.Changeset.for_create(:add, %{
            cart_id: cart_id,
            product_id: product_id,
            quantity: 1
          })
          |> Ash.create!()
        end

        # Broadcast for PubSub invalidation
        Lavash.PubSub.broadcast(CartItem)
      end
    end

    action :update_cart_item, [:item_id, :delta] do
      set :_pending_item_id, & &1.params.item_id
      set :_pending_delta, &parse_delta(&1.params.delta)

      effect fn state ->
        item_id = state[:_pending_item_id]
        delta = state[:_pending_delta]

        case Ash.get(CartItem, item_id) do
          {:ok, item} ->
            new_qty = item.quantity + delta

            if new_qty <= 0 do
              Ash.destroy!(item)
            else
              item
              |> Ash.Changeset.for_update(:update_quantity, %{quantity: new_qty})
              |> Ash.update!()
            end

          _ ->
            nil
        end

        Lavash.PubSub.broadcast(CartItem)
      end
    end

    action :remove_cart_item, [:item_id] do
      set :_pending_item_id, & &1.params.item_id

      effect fn state ->
        item_id = state[:_pending_item_id]

        case Ash.get(CartItem, item_id) do
          {:ok, item} -> Ash.destroy!(item)
          _ -> nil
        end

        Lavash.PubSub.broadcast(CartItem)
      end
    end
  end

  defp parse_delta(nil), do: 0
  defp parse_delta(d) when is_integer(d), do: d
  defp parse_delta(d) when is_binary(d), do: String.to_integer(d)

  # Handle key-based mutations from CartItemList ClientComponent
  # These are sent when the component is bound to cart_items_json

  def handle_info({:lavash_component_increment, _field, %{key: item_id}}, socket) do
    case Ash.get(CartItem, item_id) do
      {:ok, item} ->
        item
        |> Ash.Changeset.for_update(:update_quantity, %{quantity: item.quantity + 1})
        |> Ash.update!()

      _ ->
        nil
    end

    Lavash.PubSub.broadcast(CartItem)
    {:noreply, socket}
  end

  def handle_info({:lavash_component_decrement, _field, %{key: item_id}}, socket) do
    case Ash.get(CartItem, item_id) do
      {:ok, item} ->
        new_qty = item.quantity - 1

        if new_qty <= 0 do
          Ash.destroy!(item)
        else
          item
          |> Ash.Changeset.for_update(:update_quantity, %{quantity: new_qty})
          |> Ash.update!()
        end

      _ ->
        nil
    end

    Lavash.PubSub.broadcast(CartItem)
    {:noreply, socket}
  end

  def handle_info({:lavash_component_remove, _field, %{key: item_id}}, socket) do
    case Ash.get(CartItem, item_id) do
      {:ok, item} -> Ash.destroy!(item)
      _ -> nil
    end

    Lavash.PubSub.broadcast(CartItem)
    {:noreply, socket}
  end

  # Mount hook to find or create cart for current user
  def on_mount(socket) do
    user = socket.assigns[:current_user]

    cart_id =
      if user do
        # Find or create cart for user
        case Cart |> Ash.Query.for_read(:for_user, %{user_id: user.id}) |> Ash.read_one() do
          {:ok, nil} ->
            # Create new cart
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

    {:ok, Lavash.Socket.put_state(socket, :cart_id, cart_id)}
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
      <div class="flex items-center justify-between py-4">
        <div class="flex-1"></div>
        <div class="text-center flex-1">
          <h1 class="text-3xl font-bold">Our Coffees</h1>
          <p class="text-base-content/70 mt-2">Freshly roasted, ethically sourced</p>
        </div>
        <div class="flex-1 flex justify-end">
          <!-- Cart Button -->
          <button
            class="btn btn-ghost btn-circle relative"
            phx-click={Phoenix.LiveView.JS.dispatch("open-panel", to: "#cart-flyover-flyover", detail: %{open: true})}
          >
            <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M3 3h2l.4 2M7 13h10l4-8H5.4M7 13L5.4 5M7 13l-2.293 2.293c-.63.63-.184 1.707.707 1.707H17m0 0a2 2 0 100 4 2 2 0 000-4zm-8 2a2 2 0 11-4 0 2 2 0 014 0z" />
            </svg>
            <span
              :if={@cart_item_count > 0}
              class="badge badge-sm badge-primary absolute -top-1 -right-1"
            >
              {@cart_item_count}
            </span>
          </button>
        </div>
      </div>

      <!-- Filters -->
      <div class="card bg-base-200 p-4">
        <div class="flex flex-wrap gap-6">
          <!-- Roast Level Filter (static values - uses chip_set helper) -->
          <div>
            <h3 class="text-sm font-semibold text-base-content/60 mb-2">Roast Level</h3>
            <.chip_set
              field={:roast}
              chips={@roast_chips}
              values={["light", "medium", "medium_dark", "dark"]}
              labels={%{"medium_dark" => "Med-Dark"}}
            />
          </div>

          <!-- Category Filter (dynamic values from read) -->
          <div>
            <h3 class="text-sm font-semibold text-base-content/60 mb-2">Category</h3>
            <.chip_set
              field={:category}
              chips={@category_chips}
              values={Enum.map(@categories, & &1.slug)}
              labels={Map.new(@categories, &{&1.slug, &1.name})}
            />
          </div>

          <!-- In Stock Filter (boolean toggle) -->
          <div>
            <h3 class="text-sm font-semibold text-base-content/60 mb-2">Availability</h3>
            <.toggle_chip field={:in_stock} active={@in_stock} chip={@in_stock_chip} label="In Stock Only" />
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
                <span class="text-amber-500 text-sm">{"★" |> String.duplicate(round(Decimal.to_float(product.rating)))}</span>
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
                    phx-click={
                      Phoenix.LiveView.JS.push("add_to_cart", value: %{"product_id" => product.id})
                      |> Phoenix.LiveView.JS.dispatch("open-panel", to: "#cart-flyover-flyover", detail: %{open: true})
                    }
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

      <!-- Cart Flyover -->
      <.lavash_component
        module={DemoWeb.CartFlyover}
        id="cart-flyover"
        items={@cart_items_json}
        item_count={@cart_item_count}
      />

      <script :type={Phoenix.LiveView.ColocatedJS} name="optimistic">
        // Client-side optimistic functions for dynamic filter chips
        // Note: toggle_roast, toggle_in_stock, roast_chips, and in_stock_chip
        // are auto-generated from the DSL. Only custom functions needed here.

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
          // Action for dynamic category values
          toggle_category(state, value) {
            return { category: toggleInList(state.category, value) };
          },

          // Derive for dynamic category chips (values come from read result)
          category_chips(state) {
            // Use category_slugs from initial render data if available
            const slugs = state._category_slugs || [];
            const result = {};
            for (const slug of slugs) {
              result[slug] = chipClass((state.category || []).includes(slug));
            }
            return result;
          }

          // Cart optimistic updates are handled by CartItemList ClientComponent
        };
      </script>
    </div>
    """
  end
end
