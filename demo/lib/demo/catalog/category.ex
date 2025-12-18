defmodule Demo.Catalog.Category do
  use Ash.Resource,
    domain: Demo.Catalog,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "categories"
    repo(Demo.Repo)
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
    end

    attribute :slug, :string do
      allow_nil? false
    end

    timestamps()
  end

  identities do
    identity :unique_slug, [:slug]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:name, :slug]
    end

    update :update do
      accept [:name, :slug]
    end
  end
end
