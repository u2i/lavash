defmodule Demo.Catalog.Domain do
  use Ash.Domain

  resources do
    resource Demo.Catalog.Product
  end
end
