defmodule Demo.Catalog do
  @moduledoc """
  The Catalog domain.
  """
  use Ash.Domain

  alias Demo.Catalog.Product

  resources do
    resource Product do
      define :get_product, action: :read, get_by: [:id]
      define :list_products, action: :list, args: [:search, :category, :in_stock, :min_price, :max_price, :min_rating]
      define :create_product, action: :create
      define :update_product, action: :update
      define :delete_product, action: :destroy
    end
  end

  @doc """
  Returns distinct category values.
  """
  def list_categories do
    case __MODULE__.list_products(nil, nil, nil, nil, nil, nil) do
      {:ok, products} ->
        products
        |> Enum.map(& &1.category)
        |> Enum.uniq()
        |> Enum.sort()

      _ ->
        []
    end
  end

  @doc """
  Returns a new (unsaved) product struct.
  """
  def new_product do
    %Product{}
  end

  @doc """
  Returns a changeset for create or update based on whether product has an id.
  """
  def change_product(%Product{} = product, attrs \\ %{}) do
    if product.id do
      Ash.Changeset.for_update(product, :update, attrs)
    else
      Ash.Changeset.for_create(Product, :create, attrs)
    end
  end
end
