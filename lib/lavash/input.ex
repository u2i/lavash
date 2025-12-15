defmodule Lavash.Input do
  @moduledoc """
  A unified input field declaration.

  Inputs are mutable state values with a storage location:
  - `:url` - bidirectionally synced with the URL (query params or path)
  - `:socket` - survives reconnects via JS sync, lost on page refresh
  - `:ephemeral` - socket-only, lost on disconnect

  For `:form` type inputs, additional options:
  - `resource` - the Ash resource module
  - `init_from` - dependency for initialization (e.g., `result(:product)`)
  - `create` / `update` - action names for create/update operations

  Inspired by Reactor's `input` declarations.
  """

  defstruct [
    :name,
    :type,
    :from,
    :default,
    :required,
    :encode,
    :decode,
    # Form-specific options
    :resource,
    :init_from,
    :create,
    :update,
    __spark_metadata__: nil
  ]
end
