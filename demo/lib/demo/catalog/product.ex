defmodule Demo.Catalog.Product do
  use Ash.Resource,
    domain: Demo.Catalog,
    data_layer: AshSqlite.DataLayer,
    extensions: [Lavash.Resource]

  lavash do
    notify_on [:category_id, :in_stock]
  end

  sqlite do
    table "products"
    repo(Demo.Repo)
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
    end

    attribute :description, :string

    attribute :price, :decimal do
      allow_nil? false
    end

    attribute :weight_oz, :integer do
      default 12
      description "Weight in ounces"
    end

    attribute :origin, :string do
      description "Country or region of origin"
    end

    attribute :roast_level, :atom do
      constraints one_of: [:light, :medium, :medium_dark, :dark]
      default :medium
    end

    attribute :tasting_notes, :string do
      description "Flavor profile and tasting notes"
    end

    attribute :in_stock, :boolean do
      default true
    end

    attribute :rating, :decimal

    timestamps()
  end

  relationships do
    belongs_to :category, Demo.Catalog.Category do
      allow_nil? true
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:name, :description, :price, :weight_oz, :origin, :roast_level, :tasting_notes, :in_stock, :rating, :category_id]
    end

    update :update do
      accept [:name, :description, :price, :weight_oz, :origin, :roast_level, :tasting_notes, :in_stock, :rating, :category_id]
    end

    read :list do
      argument :search, :string
      argument :category_id, :uuid
      argument :in_stock, :boolean
      argument :min_price, :decimal
      argument :max_price, :decimal
      argument :min_rating, :decimal

      prepare fn query, _context ->
        Ash.Query.sort(query, :name)
      end

      filter expr(
               (is_nil(^arg(:search)) or contains(name, ^arg(:search))) and
                 (is_nil(^arg(:category_id)) or category_id == ^arg(:category_id)) and
                 (is_nil(^arg(:in_stock)) or in_stock == ^arg(:in_stock)) and
                 (is_nil(^arg(:min_price)) or price >= ^arg(:min_price)) and
                 (is_nil(^arg(:max_price)) or price <= ^arg(:max_price)) and
                 (is_nil(^arg(:min_rating)) or rating >= ^arg(:min_rating))
             )
    end
  end
end
