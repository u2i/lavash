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
  projected onto the client as optimistic state, mutated through the
  `mutate`/`remove`/`append` ops — each predicts client-side, drives
  the Ash write server-side, and is confirmed by the same event's
  re-read.
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
      mutate :items, :update_quantity, rx(%{quantity: @item.quantity + 1})
    end

    action :decrement, [:id] do
      mutate :items,
             :update_quantity,
             rx(if @item.quantity <= 1, do: :remove, else: %{quantity: @item.quantity - 1})
    end

    action :remove, [:id] do
      remove :items
    end

    action :add_item, [:name] do
      append :items,
             :create,
             rx(%{cart_id: @cart_id, name: @name, quantity: 1, unit_price: "2.50"})
    end
  end

  template do
    ~H"""
    <div id="client-cart">
      <span id="count">{@item_count}</span>
      <div :for={item <- @items} class="cart-row" id={"item-#{item.id}"}>
        <span class="row-name">{item.name}</span>
        <span class="qty">{item.quantity}</span>
        <button phx-click="increment" phx-value-id={item.id}>+</button>
        <button phx-click="decrement" phx-value-id={item.id}>-</button>
        <button phx-click="remove" phx-value-id={item.id}>x</button>
      </div>
      <button id="add-widget" phx-click="add_item" phx-value-name="Widget">add</button>
    </div>
    """
  end
end
