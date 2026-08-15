defmodule DemoWeb.DevController do
  @moduledoc """
  Dev-tools endpoints. `reset/2` wipes everything the current
  (anonymous) visitor owns — todos, carts, orders, addresses — so the
  demo starts fresh without needing a new browser session.
  """
  use DemoWeb, :controller

  require Ash.Query

  def reset(conn, _params) do
    user = conn.assigns.current_user

    if user do
      wipe_user_data(user)

      # Cross-session lavash reads re-pull on the broadcasts fired by
      # the destroys' callers; these cover the resources whose writes
      # normally go through non-lavash paths.
      Enum.each(
        [Demo.Todos.Todo, Demo.Cart.CartItem, Demo.Cart.Cart, Demo.Orders.Address],
        &Lavash.PubSub.broadcast/1
      )
    end

    conn
    |> put_flash(:info, "Your demo data has been reset.")
    |> redirect(to: safe_referer(conn))
  end

  defp wipe_user_data(user) do
    # Children before parents (SQLite enforces the FKs).
    carts =
      Demo.Cart.Cart
      |> Ash.Query.filter(user_id == ^user.id)
      |> Ash.read!()

    for cart <- carts do
      Demo.Cart.CartItem
      |> Ash.Query.filter(cart_id == ^cart.id)
      |> Ash.read!()
      |> Enum.each(&Ash.destroy!/1)
    end

    orders =
      Demo.Orders.Order
      |> Ash.Query.filter(user_id == ^user.id)
      |> Ash.read!()

    for order <- orders do
      Demo.Orders.OrderItem
      |> Ash.Query.filter(order_id == ^order.id)
      |> Ash.read!()
      |> Enum.each(&Ash.destroy!/1)
    end

    Enum.each(orders, &Ash.destroy!/1)
    Enum.each(carts, &Ash.destroy!/1)

    Demo.Orders.Address
    |> Ash.Query.filter(user_id == ^user.id)
    |> Ash.read!()
    |> Enum.each(&Ash.destroy!/1)

    Demo.Todos.Todo
    |> Ash.Query.filter(user_id == ^user.id)
    |> Ash.read!()
    |> Enum.each(&Ash.destroy!/1)
  end

  # Bounce back to wherever the reset was clicked from; internal paths only.
  defp safe_referer(conn) do
    case get_req_header(conn, "referer") do
      [ref | _] ->
        case URI.parse(ref) do
          %URI{path: path} when is_binary(path) -> path
          _ -> "/"
        end

      _ ->
        "/"
    end
  end
end
