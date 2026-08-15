defmodule Demo.Cart do
  use Ash.Domain

  resources do
    resource Demo.Cart.Cart
    resource Demo.Cart.CartItem
  end
end
