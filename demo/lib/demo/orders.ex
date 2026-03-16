defmodule Demo.Orders do
  use Ash.Domain

  resources do
    resource Demo.Orders.Order
    resource Demo.Orders.OrderItem
    resource Demo.Orders.Address
  end
end
