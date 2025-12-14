defmodule Demo.Catalog do
  import Ecto.Query
  alias Demo.Repo
  alias Demo.Catalog.Product

  # Ash-based functions for form handling
  def get_product(id) do
    Ash.get(Product, id)
  end

  def get_product!(id) do
    Ash.get!(Product, id)
  end

  def update_product(%Product{} = product, attrs) do
    product
    |> Ash.Changeset.for_update(:update, attrs)
    |> Ash.update()
  end

  def change_product(%Product{} = product, attrs \\ %{}) do
    Ash.Changeset.for_update(product, :update, attrs)
  end

  # Ecto-based functions for list/filter (keeping for compatibility)
  def list_products(filters \\ %{}) do
    Product
    |> apply_filters(filters)
    |> order_by([p], asc: p.name)
    |> Repo.all()
  end

  def list_categories do
    Product
    |> select([p], p.category)
    |> distinct(true)
    |> order_by([p], asc: p.category)
    |> Repo.all()
  end

  defp apply_filters(query, filters) do
    query
    |> filter_by_search(filters[:search])
    |> filter_by_category(filters[:category])
    |> filter_by_in_stock(filters[:in_stock])
    |> filter_by_min_price(filters[:min_price])
    |> filter_by_max_price(filters[:max_price])
    |> filter_by_min_rating(filters[:min_rating])
  end

  defp filter_by_search(query, nil), do: query
  defp filter_by_search(query, ""), do: query
  defp filter_by_search(query, search) do
    search_term = "%#{search}%"
    where(query, [p], ilike(p.name, ^search_term))
  end

  defp filter_by_category(query, nil), do: query
  defp filter_by_category(query, ""), do: query
  defp filter_by_category(query, category) do
    where(query, [p], p.category == ^category)
  end

  defp filter_by_in_stock(query, nil), do: query
  defp filter_by_in_stock(query, in_stock) when is_boolean(in_stock) do
    where(query, [p], p.in_stock == ^in_stock)
  end
  defp filter_by_in_stock(query, _), do: query

  defp filter_by_min_price(query, nil), do: query
  defp filter_by_min_price(query, min) when is_number(min) do
    where(query, [p], p.price >= ^min)
  end
  defp filter_by_min_price(query, _), do: query

  defp filter_by_max_price(query, nil), do: query
  defp filter_by_max_price(query, max) when is_number(max) do
    where(query, [p], p.price <= ^max)
  end
  defp filter_by_max_price(query, _), do: query

  defp filter_by_min_rating(query, nil), do: query
  defp filter_by_min_rating(query, min) when is_number(min) do
    where(query, [p], p.rating >= ^min)
  end
  defp filter_by_min_rating(query, _), do: query
end
