defmodule Lavash.Argument do
  @moduledoc """
  An argument declaration for derive/form entities.

  Arguments wire dependencies using Reactor-inspired syntax:
  - `argument :id, state(:product_id)` - depends on a state field
  - `argument :record, result(:product)` - depends on another derivation's result

  The source is stored as a tuple: `{:state, :field_name}` or `{:result, :field_name}`.
  """

  defstruct [
    :name,
    :source,
    __spark_metadata__: nil
  ]
end
