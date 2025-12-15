defmodule Lavash.Input do
  @moduledoc """
  A unified input field declaration.

  Inputs are mutable state values with a storage location:
  - `:url` - bidirectionally synced with the URL (query params or path)
  - `:socket` - survives reconnects via JS sync, lost on page refresh
  - `:ephemeral` - socket-only, lost on disconnect

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
    __spark_metadata__: nil
  ]
end
