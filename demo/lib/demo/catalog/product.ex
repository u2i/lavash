defmodule Demo.Catalog.Product do
  use Ash.Resource,
    domain: Demo.Catalog,
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
    defaults [:read, :destroy]

    create :create do
      accept [:name, :category, :price, :in_stock, :rating]
    end

    update :update do
      accept [:name, :category, :price, :in_stock, :rating]
    end

    read :list do
      argument :search, :string
      argument :category, :string
      argument :in_stock, :boolean
      argument :min_price, :decimal
      argument :max_price, :decimal
      argument :min_rating, :decimal

      prepare fn query, _context ->
        Ash.Query.sort(query, :name)
      end

      filter expr(
        (is_nil(^arg(:search)) or contains(name, ^arg(:search))) and
        (is_nil(^arg(:category)) or category == ^arg(:category)) and
        (is_nil(^arg(:in_stock)) or in_stock == ^arg(:in_stock)) and
        (is_nil(^arg(:min_price)) or price >= ^arg(:min_price)) and
        (is_nil(^arg(:max_price)) or price <= ^arg(:max_price)) and
        (is_nil(^arg(:min_rating)) or rating >= ^arg(:min_rating))
      )
    end

    action :list_categories, {:array, :string} do
      run fn _input, _context ->
        {:ok, products} = Ash.read(__MODULE__)

        categories =
          products
          |> Enum.map(& &1.category)
          |> Enum.sort()
          |> Enum.uniq()

        {:ok, categories}
      end
    end
  end
end
