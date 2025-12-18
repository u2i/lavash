defmodule Lavash.Read do
  @moduledoc """
  A read step that loads an Ash resource.

  Supports two modes:

  ## Get by ID (single record)

      read :product, Product do
        id state(:product_id)
      end

  ## Query with auto-mapped arguments

      # Auto-maps state fields to action arguments by name
      read :products, Product, :list

      # With explicit overrides
      read :products, Product, :list do
        argument :category, transform: &(if &1 == "", do: nil, else: &1)
      end

  Action arguments are auto-wired to matching state fields. Use `argument` entities
  to override the source or apply transforms.
  """

  defstruct [
    :name,
    :resource,
    :id,
    :action,
    :async,
    :as_options,
    :invalidate_on,
    arguments: [],
    __spark_metadata__: nil
  ]
end

defmodule Lavash.Read.Argument do
  @moduledoc """
  An argument override for a read action.

  Used to customize how state maps to action arguments:
  - Override the source (e.g., map a differently-named state field)
  - Apply a transform function
  """

  defstruct [
    :name,
    :source,
    :transform,
    __spark_metadata__: nil
  ]
end
