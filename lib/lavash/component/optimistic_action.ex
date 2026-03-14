defmodule Lavash.Component.OptimisticAction do
  @moduledoc """
  An optimistic action that generates both client JS and server handlers.

  Optimistic actions define state transformations that run on both client
  and server. The `run` function is compiled to both Elixir and JavaScript,
  ensuring consistent behavior.

  ## Fields

  - `:name` - The action name (used for event routing)
  - `:field` - The state field this action operates on
  - `:key` - For array-of-objects: the field used to identify items (e.g., :id)
  - `:run` - Function that transforms the field value (or `:remove` atom)
  - `:run_source` - Source string for JS compilation
  - `:validate` - Optional validation function
  - `:validate_source` - Source string for JS validation
  - `:max` - Optional prop/state field containing max length limit
  """
  defstruct [:name, :field, :key, :run, :run_source, :validate, :validate_source, :max, __spark_metadata__: nil]
end
