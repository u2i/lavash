defmodule Lavash.Read do
  @moduledoc """
  A read step that loads an Ash resource by ID.

  Expands to a derived field that async loads the resource.

  ## Example

      read :product, Product do
        id input(:product_id)
      end

  This is equivalent to:

      derive :product do
        argument :id, input(:product_id)
        async true
        run fn %{id: id}, _ ->
          case id do
            nil -> nil
            id -> Ash.get!(Product, id)
          end
        end
      end
  """

  defstruct [
    :name,
    :resource,
    :id,
    :action,
    :async,
    __spark_metadata__: nil
  ]
end
