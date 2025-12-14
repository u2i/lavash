defmodule Demo.Catalog.Product do
  use Ecto.Schema
  import Ecto.Changeset

  schema "products" do
    field :name, :string
    field :category, :string
    field :price, :decimal
    field :in_stock, :boolean, default: true
    field :rating, :decimal

    timestamps(type: :utc_datetime)
  end

  def changeset(product, attrs) do
    product
    |> cast(attrs, [:name, :category, :price, :in_stock, :rating])
    |> validate_required([:name, :category, :price])
  end
end
