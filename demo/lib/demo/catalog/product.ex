defmodule Demo.Catalog.Product do
  use Ash.Resource,
    domain: Demo.Catalog.Domain,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "products"
    repo Demo.Repo
  end

  attributes do
    integer_primary_key :id

    attribute :name, :string do
      allow_nil? false
    end

    attribute :category, :string do
      allow_nil? false
    end

    attribute :price, :decimal do
      allow_nil? false
    end

    attribute :in_stock, :boolean do
      default true
    end

    attribute :rating, :decimal

    timestamps()
  end

  actions do
    defaults [:read]

    create :create do
      accept [:name, :category, :price, :in_stock, :rating]
    end

    update :update do
      accept [:name, :category, :price, :in_stock, :rating]
    end
  end
end
