defmodule Lavash.StateField do
  @moduledoc """
  A mutable state field from an external source.

  State fields declare where mutable state comes from:
  - `:url` - bidirectionally synced with the URL (query params or path)
  - `:socket` - survives reconnects via JS client sync
  - `:ephemeral` - socket-only, lost on disconnect (default)

  ## Example

      state :product_id, :integer, from: :url
      state :form_params, :map, from: :ephemeral, default: %{}
  """

  defstruct [
    :name,
    :type,
    :from,
    :default,
    :required,
    :encode,
    :decode,
    :setter,
    :optimistic,
    __spark_metadata__: nil
  ]
end
