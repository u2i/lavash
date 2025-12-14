defmodule Demo.Repo.Migrations.CreateProducts do
  use Ecto.Migration

  def change do
    create table(:products) do
      add :name, :string, null: false
      add :category, :string, null: false
      add :price, :decimal, null: false
      add :in_stock, :boolean, default: true
      add :rating, :decimal

      timestamps(type: :utc_datetime)
    end

    create index(:products, [:category])
    create index(:products, [:in_stock])
    create index(:products, [:price])
  end
end
