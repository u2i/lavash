defmodule Lavash.Input do
  @moduledoc """
  A mutable state input from an external source.

  Inputs declare where mutable state comes from:
  - `:url` - bidirectionally synced with the URL (query params or path)
  - `:socket` - survives reconnects via JS client sync
  - `:ephemeral` - socket-only, lost on disconnect (default)

  ## Example

      input :product_id, :integer, from: :url
      input :form_params, :map, from: :ephemeral, default: %{}
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
