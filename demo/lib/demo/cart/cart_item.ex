defmodule Demo.Cart.CartItem do
  use Ash.Resource,
    domain: Demo.Cart,
    data_layer: AshSqlite.DataLayer,
    extensions: [Lavash.Resource]

  # Broadcast changes via PubSub for automatic LiveView refresh
  # We notify on cart_id so that reads filtered by cart_id are invalidated
  lavash do
    notify_on [:cart_id]
  end

  sqlite do
    table "cart_items"
    repo(Demo.Repo)
  end

  attributes do
    uuid_primary_key :id

    attribute :quantity, :integer do
      allow_nil? false
      default 1
      constraints min: 1
    end

    attribute :unit_price, :decimal do
      allow_nil? false
    end

    timestamps()
  end

  relationships do
    belongs_to :cart, Demo.Cart.Cart, allow_nil?: false
    belongs_to :product, Demo.Catalog.Product, allow_nil?: false
  end

  calculations do
    calculate :line_total, :decimal, expr(quantity * unit_price)
  end

  actions do
    defaults [:read, :destroy]

    # Public add: create-or-increment (manual). Adding a product already
    # in the cart bumps its quantity instead of duplicating the row —
    # dedup lives in the domain layer, so every caller (pages, the cart
    # flyover's `append`) gets it for free.
    create :add do
      accept [:quantity]
      argument :cart_id, :uuid, allow_nil?: false
      argument :product_id, :uuid, allow_nil?: false

      manual Demo.Cart.CreateOrIncrementCartItem
    end

    # Raw row creation used by :add's manual implementation.
    create :create_row do
      accept [:quantity]
      argument :cart_id, :uuid, allow_nil?: false
      argument :product_id, :uuid, allow_nil?: false

      change manage_relationship(:cart_id, :cart, type: :append)
      change manage_relationship(:product_id, :product, type: :append)

      # Snapshot the product price at time of adding
      change fn changeset, _context ->
        product_id = Ash.Changeset.get_argument(changeset, :product_id)

        if product_id do
          case Ash.get(Demo.Catalog.Product, product_id) do
            {:ok, product} ->
              Ash.Changeset.force_change_attribute(changeset, :unit_price, product.price)

            _ ->
              changeset
          end
        else
          changeset
        end
      end
    end

    update :update_quantity do
      accept [:quantity]
    end

    read :for_cart do
      argument :cart_id, :uuid, allow_nil?: true
      filter expr(not is_nil(^arg(:cart_id)) and cart_id == ^arg(:cart_id))
      prepare build(load: [:product, :line_total])
    end
  end

  identities do
    identity :unique_cart_product, [:cart_id, :product_id]
  end
end
