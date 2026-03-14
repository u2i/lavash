defmodule Lavash.Component.Calculate do
  @moduledoc """
  A calculated field computed from state using a reactive expression.

  Calculations use `rx()` to capture expressions that reference state via
  `@field` syntax. By default, they are transpiled to JavaScript for
  client-side optimistic updates.

  ## Fields

  - `:name` - The atom name of the calculated field
  - `:rx` - A `Lavash.Rx` struct containing the expression
  - `:optimistic` - Whether to transpile to JS (default: true, auto-set to false if not transpilable)
  - `:async` - Whether to compute asynchronously (default: false)
  - `:reads` - Ash resources to watch for PubSub invalidation (default: [])

  ## Usage

      # Simple reactive calculation - transpiles to JS
      calculate :tag_count, rx(length(@tags))
      calculate :can_add, rx(@max == nil or length(@items) < @max)

      # Server-only (explicit or auto-detected)
      calculate :server_only, rx(complex_fn(@data)), optimistic: false

      # Async calculation - returns AsyncResult (loading/ok/error)
      calculate :factorial, rx(compute_factorial(@n)), async: true

      # With resource invalidation
      calculate :product_count, rx(length(@products)), reads: [Product]
  """
  defstruct [:name, :rx, optimistic: true, async: false, reads: [], __spark_metadata__: nil]
end
