defmodule Demo.Orders do
  use Ash.Domain

  require Ash.Query

  resources do
    resource Demo.Orders.Order
    resource Demo.Orders.OrderItem
    resource Demo.Orders.Address
  end

  @doc """
  Deletes the user's orders (items first — SQLite enforces the FKs)
  and addresses, and broadcasts invalidation so open sessions
  re-read. Backs the demo's Reset dev tool.
  """
  def wipe_for_user!(user_id) do
    orders =
      Demo.Orders.Order
      |> Ash.Query.for_read(:for_user, %{user_id: user_id})
      |> Ash.read!()

    for order <- orders do
      Demo.Orders.OrderItem
      |> Ash.Query.filter(order_id == ^order.id)
      |> Ash.read!()
      |> Enum.each(&Ash.destroy!/1)
    end

    Enum.each(orders, &Ash.destroy!/1)

    Demo.Orders.Address
    |> Ash.Query.for_read(:for_user, %{user_id: user_id})
    |> Ash.read!()
    |> Enum.each(&Ash.destroy!/1)

    Lavash.PubSub.broadcast(Demo.Orders.Address)
    :ok
  end
end
