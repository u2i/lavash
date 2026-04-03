defmodule DemoWeb.Storefront.ProductLive do
  use Lavash.LiveView
  import Lavash.LiveView.Helpers

  use Phoenix.VerifiedRoutes,
    endpoint: DemoWeb.Endpoint,
    router: DemoWeb.Router,
    statics: DemoWeb.static_paths()

  alias Demo.Catalog.Product
  alias Demo.Cart.{Cart, CartItem}

  # Product loaded on mount from path param
  state :product, :any, from: :ephemeral
  state :product_id, :string, from: :url

  # Cart state (same pattern as ProductsLive)
  state :cart_id, :string, from: :ephemeral
  state :cart_open, :any, from: :ephemeral, default: nil, optimistic: true

  # Cart reads
  read :cart_items, CartItem, :for_cart do
    argument :cart_id, state(:cart_id)
    async false
    invalidate :pubsub
  end

  # Cart calculations
  calculate :cart_items_json, rx(serialize_cart_items(@cart_items)), optimistic: false

  calculate :cart_item_count,
            rx(Enum.reduce(@cart_items, 0, fn item, acc -> acc + item.quantity end))

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

  actions do
    action :open_cart do
      set :cart_open, true
    end

    action :add_to_cart do
      set :cart_open, true

      effect fn state ->
        cart_id = state.cart_id
        product_id = state.product_id

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

  # Handle key-based mutations from CartItemList component
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

  # Mount: load product and find/create cart
  def on_mount(socket) do
    product_id = socket.assigns[:product_id]

    socket =
      case Ash.get(Product, product_id) do
        {:ok, product} ->
          Lavash.Socket.put_state(socket, :product, product)

        {:error, _} ->
          Phoenix.LiveView.push_navigate(socket, to: ~p"/storefront/products")
      end

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

    {:ok, Lavash.Socket.put_state(socket, :cart_id, cart_id)}
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

  defp roast_badge(assigns) do
    {color, label} =
      case assigns.level do
        :light -> {"bg-amber-100 text-amber-800", "Light Roast"}
        :medium -> {"bg-orange-100 text-orange-800", "Medium Roast"}
        :medium_dark -> {"bg-orange-200 text-orange-900", "Medium-Dark Roast"}
        :dark -> {"bg-stone-700 text-stone-100", "Dark Roast"}
        _ -> {"bg-base-300 text-base-content", "Unknown"}
      end

    assigns = assign(assigns, color: color, label: label)

    ~H"""
    <span class={"text-sm px-3 py-1 rounded-full font-medium #{@color}"}>
      {@label}
    </span>
    """
  end

  render fn assigns ->
    ~L"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <a href={~p"/storefront/products"} class="btn btn-ghost btn-sm">
          &larr; Back to Coffees
        </a>
        <!-- Cart Button -->
        <button
          class="btn btn-ghost btn-circle relative"
          phx-click="open_cart"
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

      <div class="grid md:grid-cols-2 gap-8">
        <div class="card bg-base-200 overflow-hidden">
          <figure>
            <img
              src={"https://images.unsplash.com/#{coffee_image(@product.roast_level)}?w=600&q=80"}
              alt={@product.name}
              class="w-full h-80 object-cover"
            />
          </figure>
        </div>

        <div class="space-y-6">
          <div>
            <div class="flex items-start justify-between gap-4">
              <h1 class="text-3xl font-bold">{@product.name}</h1>
              <.roast_badge level={@product.roast_level} />
            </div>
            <p class="text-lg text-base-content/70 mt-1">{@product.origin}</p>
          </div>

          <p class="text-base-content/80">{@product.description}</p>

          <div class="flex items-center gap-2">
            <span class="text-amber-500 text-lg">{"★" |> String.duplicate(round(Decimal.to_float(@product.rating)))}</span>
            <span class="text-base-content/70">{Decimal.to_string(@product.rating)} / 5</span>
          </div>

          <div class="card bg-base-200">
            <div class="card-body p-4">
              <h3 class="font-semibold text-sm uppercase tracking-wide text-base-content/60">Tasting Notes</h3>
              <p class="mt-1">{@product.tasting_notes}</p>
            </div>
          </div>

          <div class="flex items-center gap-4">
            <span class={["badge badge-lg", @product.in_stock && "badge-success", !@product.in_stock && "badge-error"]}>
              {if @product.in_stock, do: "In Stock", else: "Sold Out"}
            </span>
            <span class="text-sm text-base-content/60">{@product.weight_oz}oz bag</span>
          </div>

          <div class="divider"></div>

          <div class="flex items-center justify-between">
            <span class="text-3xl font-bold">${Decimal.to_string(@product.price)}</span>
            <%= if @product.in_stock do %>
              <button class="btn btn-primary btn-lg" phx-click="add_to_cart">
                Add to Cart
              </button>
            <% else %>
              <button class="btn btn-lg" disabled>Notify Me</button>
            <% end %>
          </div>
        </div>
      </div>

      <!-- Cart Flyover -->
      <.lavash_component
        module={DemoWeb.CartFlyover}
        id="cart-flyover"
        items={@cart_items_json}
        item_count={@cart_item_count}
        open={@cart_open}
        bind={[open: :cart_open]}
      />
    </div>
    """
  end
end
