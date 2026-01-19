defmodule Lavash.Actions.Set do
  @moduledoc """
  Sets a field to a value.

  The value expression uses `@field` syntax to reference state and params,
  aligned with template syntax. At compile time, the expression is stored
  as both source (for JS transpilation) and a transformed function
  (for server-side evaluation).

  ## Examples

      set :count, @count + 1
      set :items, @items ++ [@name]
      set :total, @price * @quantity
  """
  defstruct [
    :field,
    # The original value expression (can be a literal, quoted AST, or function)
    :value,
    # Source string of the expression (for JS transpilation)
    :source,
    # Dependencies extracted from @field references
    :deps,
    __spark_metadata__: nil
  ]
end
