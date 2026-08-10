defmodule Lavash.Test.Magic.ClientCart do
  @moduledoc "Domain for the client_state projection fixture."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(Lavash.Test.Magic.ClientCart.Item)
  end
end

defmodule Lavash.Test.Magic.ClientCart.Item do
  @moduledoc "Minimal cart item resource backing the client_state fixture."
  use Ash.Resource,
    domain: Lavash.Test.Magic.ClientCart,
    data_layer: Ash.DataLayer.Ets

  ets do
    # Shared table: tests create items in the test process, the
    # LiveView process reads them.
    private?(false)
  end

  attributes do
    uuid_primary_key(:id)

    attribute :cart_id, :string do
      public?(true)
    end

    attribute :name, :string do
      public?(true)
    end

    attribute :quantity, :integer do
      public?(true)
    end

    attribute :unit_price, :decimal do
      public?(true)
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:cart_id, :name, :quantity, :unit_price])
    end

    update :update_quantity do
      accept([:quantity])
    end

    read :for_cart do
      argument(:cart_id, :string, allow_nil?: false)
      filter(expr(cart_id == ^arg(:cart_id)))
    end
  end
end

defmodule Lavash.Test.Magic.ClientCartLive do
  @moduledoc """
  Fixture exercising `client_state` projections: a query read
  projected onto the client as optimistic state, with a `map_by`
  prediction whose durable write happens in `pre_run` and is
  confirmed by the same event's re-read.
  """
  use Lavash.LiveView

  alias Lavash.Test.Magic.ClientCart.Item

  state :cart_id, :string, from: :url

  read :cart_items, Item, :for_cart do
    argument :cart_id, state(:cart_id)
    async false

    client_state :items do
      key :id
      fields [:id, :name, :quantity, :unit_price]
    end
  end

  calculate :item_count,
            rx(Enum.reduce(@items || [], 0, fn item, acc -> acc + item.quantity end))

  actions do
    action :increment, [:id] do
      map_by :items, :id, "fn item, _id -> %{item | quantity: item.quantity + 1} end"

      pre_run fn socket ->
        item = Ash.get!(Item, socket.assigns.id)

        item
        |> Ash.Changeset.for_update(:update_quantity, %{quantity: item.quantity + 1})
        |> Ash.update!()

        Lavash.PubSub.broadcast(Item)
        socket
      end
    end

    action :remove, [:id] do
      map_by :items, :id, :remove

      pre_run fn socket ->
        Item |> Ash.get!(socket.assigns.id) |> Ash.destroy!()
        Lavash.PubSub.broadcast(Item)
        socket
      end
    end
  end

  template do
    ~H"""
    <div id="client-cart">
      <span id="count">{@item_count}</span>
      <div :for={item <- @items} class="cart-row" id={"item-#{item.id}"}>
        <span class="qty">{item.quantity}</span>
        <button phx-click="increment" phx-value-id={item.id}>+</button>
        <button phx-click="remove" phx-value-id={item.id}>x</button>
      </div>
    </div>
    """
  end
end
