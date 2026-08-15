defmodule Demo.Cart do
  use Ash.Domain

  require Ash.Query

  resources do
    resource Demo.Cart.Cart
    resource Demo.Cart.CartItem
  end

  @doc """
  Deletes the user's carts and their items (children first — SQLite
  enforces the FKs) and broadcasts invalidation so open sessions
  re-read. Backs the demo's Reset dev tool.
  """
  def wipe_for_user!(user_id) do
    carts =
      Demo.Cart.Cart
      |> Ash.Query.for_read(:for_user, %{user_id: user_id})
      |> Ash.read!()

    for cart <- carts do
      Demo.Cart.CartItem
      |> Ash.Query.for_read(:for_cart, %{cart_id: cart.id})
      |> Ash.read!()
      |> Enum.each(&Ash.destroy!/1)
    end

    Enum.each(carts, &Ash.destroy!/1)

    Lavash.PubSub.broadcast(Demo.Cart.CartItem)
    Lavash.PubSub.broadcast(Demo.Cart.Cart)
    :ok
  end
end
