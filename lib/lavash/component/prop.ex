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
  - `:client` - Whether to include in client state JSON (default: true)
  """
  defstruct [:name, :type, :required, :default, client: true, __spark_metadata__: nil]
end
