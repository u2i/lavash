defmodule DemoWeb.Storefront.ProductLive do
  use Lavash.LiveView
  import Lavash.LiveView.Helpers

  use Phoenix.VerifiedRoutes,
    endpoint: DemoWeb.Endpoint,
    router: DemoWeb.Router,
    statics: DemoWeb.static_paths()

  alias Demo.Cart.{Cart, CartItem}
  alias Demo.Catalog.Product

  # Product loaded on mount from path param
  state :product, :any, from: :ephemeral
  state :product_id, :string, from: :url

  # Cart state (same pattern as ProductsLive)
  state :cart_id, :string, from: :ephemeral
  state :cart_open, :any, from: :ephemeral, default: nil, optimistic: true

  # Quantity selector — bumped/dec'd via two actions, used by add_to_cart.
  state :quantity, :integer, from: :ephemeral, default: 1, optimistic: true

  # Action-scratch state. The update/remove cart actions stash the
  # operating item id and delta here before reading it back in the
  # `run` body.
  state :_pending_item_id, :string, from: :ephemeral, default: nil
  state :_pending_delta, :integer, from: :ephemeral, default: nil

  # The cart itself is fully owned by DemoWeb.CartFlyover (trigger +
  # badge + panel) — this page only knows the cart_id.

  calculate :quantity_gt_1, rx(@quantity > 1)

  actions do
    action :inc_quantity do
      set :quantity, rx(@quantity + 1)
    end

    action :dec_quantity do
      set :quantity, rx(max(@quantity - 1, 1))
    end

    action :add_to_cart do
      set :cart_open, true

      effect fn state ->
        cart_id = state.cart_id
        product_id = state.product_id
        qty_to_add = state.quantity || 1

        # Query directly — this page no longer holds a cart read
        existing =
          CartItem
          |> Ash.Query.for_read(:for_cart, %{cart_id: cart_id})
          |> Ash.read!()
          |> Enum.find(fn item -> item.product_id == product_id end)

        if existing do
          existing
          |> Ash.Changeset.for_update(:update_quantity, %{
            quantity: existing.quantity + qty_to_add
          })
          |> Ash.update!()
        else
          CartItem
          |> Ash.Changeset.for_create(:add, %{
            cart_id: cart_id,
            product_id: product_id,
            quantity: qty_to_add
          })
          |> Ash.create!()
        end

        Lavash.PubSub.broadcast(CartItem)
      end

      # Reset back to 1 after adding so the next add starts fresh.
      set :quantity, 1
    end
  end

  # Mount: load product and find/create cart. Run via `mount do run
  # ... end` so we don't shadow lavash's imported `on_mount` macro.
  mount do
    run fn socket -> load_product_and_cart(socket) end
  end

  defp load_product_and_cart(socket) do
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

  template do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <a href={~p"/storefront/products"} class="btn btn-ghost btn-sm">
          &larr; Back to Coffees
        </a>
        <%!-- Cart: trigger (icon + optimistic badge) AND flyover panel,
             all owned by the component — this page just places it. --%>
        <.lavash_component
          module={DemoWeb.CartFlyover}
          id="cart-flyover"
          cart_id={@cart_id}
          open={@cart_open}
          bind={[open: :cart_open]}
        />
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
            <span class="text-amber-500 text-lg">{"★"
            |> String.duplicate(round(Decimal.to_float(@product.rating)))}</span>
            <span class="text-base-content/70">{Decimal.to_string(@product.rating)} / 5</span>
          </div>

          <div class="card bg-base-200">
            <div class="card-body p-4">
              <h3 class="font-semibold text-sm uppercase tracking-wide text-base-content/60">
                Tasting Notes
              </h3>
              <p class="mt-1">{@product.tasting_notes}</p>
            </div>
          </div>

          <div class="flex items-center gap-4">
            <span class={[
              "badge badge-lg",
              @product.in_stock && "badge-success",
              !@product.in_stock && "badge-error"
            ]}>
              {if @product.in_stock, do: "In Stock", else: "Sold Out"}
            </span>
            <span class="text-sm text-base-content/60">{@product.weight_oz}oz bag</span>
          </div>

          <div class="divider"></div>

          <div class="flex items-center justify-between gap-4">
            <span class="text-3xl font-bold">${Decimal.to_string(@product.price)}</span>
            <%= if @product.in_stock do %>
              <div class="flex items-center gap-3">
                <div class="join">
                  <button
                    phx-click="dec_quantity"
                    class="btn btn-sm join-item"
                    data-lavash-enabled="quantity_gt_1"
                  >
                    -
                  </button>
                  <span class="btn btn-sm join-item no-animation pointer-events-none min-w-12">
                    {@quantity}
                  </span>
                  <button
                    phx-click="inc_quantity"
                    class="btn btn-sm join-item"
                  >
                    +
                  </button>
                </div>
                <button class="btn btn-primary btn-lg" phx-click="add_to_cart">
                  Add to Cart
                </button>
              </div>
            <% else %>
              <button class="btn btn-lg" disabled>Notify Me</button>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
