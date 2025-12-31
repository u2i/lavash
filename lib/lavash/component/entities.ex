defmodule Lavash.Component.Prop do
  @moduledoc """
  A prop passed from the parent component.

  Props are read-only values that a component receives from its parent.
  They cannot be modified by the component itself.

  ## Fields

  - `:name` - The atom name of the prop
  - `:type` - The type specification (e.g., `:string`, `{:array, :string}`)
  - `:required` - Whether the prop must be provided (default: false)
  - `:default` - Default value if not provided
  """
  defstruct [:name, :type, :required, :default, __spark_metadata__: nil]
end

defmodule Lavash.Component.Template do
  @moduledoc """
  A component template that compiles to both HEEx and JS.

  The template source is parsed and transformed during compilation
  to generate both server-side HEEx rendering and client-side
  JavaScript for optimistic updates.
  """
  defstruct [:source, __spark_metadata__: nil]
end

defmodule Lavash.Component.OptimisticAction do
  @moduledoc """
  An optimistic action that generates both client JS and server handlers.

  Optimistic actions define state transformations that run on both client
  and server. The `run` function is compiled to both Elixir and JavaScript,
  ensuring consistent behavior.

  ## Fields

  - `:name` - The action name (used for event routing)
  - `:field` - The state field this action operates on
  - `:run` - Function that transforms the field value
  - `:run_source` - Source string for JS compilation
  - `:validate` - Optional validation function
  - `:validate_source` - Source string for JS validation
  - `:max` - Optional prop/state field containing max length limit
  """
  defstruct [:name, :field, :run, :run_source, :validate, :validate_source, :max, __spark_metadata__: nil]
end
