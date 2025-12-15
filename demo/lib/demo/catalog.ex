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
      define :list_categories, action: :list_categories
      define :create_product, action: :create
      define :update_product, action: :update
      define :delete_product, action: :destroy
    end
  end
end
