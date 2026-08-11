defmodule Demo.Cart.CreateOrIncrementCartItem do
  @moduledoc """
  Manual implementation of `CartItem.:add`: adding a product already
  in the cart increments its quantity instead of creating a duplicate
  row. Keeps the create-or-increment decision in the domain layer, so
  every caller (pages, the cart flyover's `append`) gets dedup for
  free.
  """
  use Ash.Resource.ManualCreate

  @impl true
  def create(changeset, _opts, _context) do
    cart_id = Ash.Changeset.get_argument(changeset, :cart_id)
    product_id = Ash.Changeset.get_argument(changeset, :product_id)
    quantity = Ash.Changeset.get_attribute(changeset, :quantity) || 1

    existing =
      Demo.Cart.CartItem
      |> Ash.Query.for_read(:for_cart, %{cart_id: cart_id})
      |> Ash.read!()
      |> Enum.find(fn item -> item.product_id == product_id end)

    if existing do
      existing
      |> Ash.Changeset.for_update(:update_quantity, %{quantity: existing.quantity + quantity})
      |> Ash.update()
    else
      Demo.Cart.CartItem
      |> Ash.Changeset.for_create(:create_row, %{
        cart_id: cart_id,
        product_id: product_id,
        quantity: quantity
      })
      |> Ash.create()
    end
  end
end
