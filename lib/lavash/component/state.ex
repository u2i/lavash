defmodule Lavash.Component.State do
  @moduledoc """
  A state field that connects component state to parent state.

  This is the unified state entity used by both LiveComponent and ClientComponent.
  State fields are bound to parent LiveView state and can be modified through
  optimistic actions.

  ## Fields

  - `:name` - The atom name of the state field
  - `:type` - The type specification (e.g., `:boolean`, `{:array, :string}`)
  - `:from` - Storage location (`:parent` for components, default)
  - `:default` - Default value if not provided

  ## Usage

  In LiveComponent or ClientComponent:

      state :tags, {:array, :string}
      state :active, :boolean, default: false

  The state field will be bound to the parent's state of the same name
  via the `bind` prop.
  """
  defstruct [:name, :type, :from, :default, __spark_metadata__: nil]
end
