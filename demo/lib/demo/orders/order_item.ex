defmodule Demo.Orders.OrderItem do
  use Ash.Resource,
    domain: Demo.Orders,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "order_items"
    repo Demo.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :quantity, :integer, allow_nil?: false
    attribute :unit_price, :decimal, allow_nil?: false

    # Denormalized product info (snapshot at time of order)
    attribute :product_name, :string, allow_nil?: false

    timestamps()
  end

  relationships do
    belongs_to :order, Demo.Orders.Order, allow_nil?: false
    belongs_to :product, Demo.Catalog.Product
  end

  calculations do
    calculate :line_total, :decimal, expr(quantity * unit_price)
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:quantity, :unit_price, :product_name]
      argument :order_id, :uuid, allow_nil?: false
      argument :product_id, :uuid

      change manage_relationship(:order_id, :order, type: :append)
      change manage_relationship(:product_id, :product, type: :append)
    end
  end
end
