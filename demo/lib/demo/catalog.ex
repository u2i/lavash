defmodule Demo.Catalog do
  @moduledoc """
  The Catalog domain.
  """
  use Ash.Domain

  alias Demo.Catalog.{Category, Product}

  resources do
    resource Category do
      define :list_categories, action: :read
      define :create_category, action: :create
    end

    resource Product do
      define :get_product, action: :read, get_by: [:id]
      define :list_products, action: :list, args: [:search, :category_id, :in_stock, :min_price, :max_price, :min_rating]
      define :create_product, action: :create
      define :update_product, action: :update
      define :delete_product, action: :destroy
    end
  end
end
