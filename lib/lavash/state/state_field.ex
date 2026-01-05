defmodule Lavash.State.Field do
  @moduledoc """
  A mutable state field from an external source.

  State fields declare where mutable state comes from:
  - `:url` - bidirectionally synced with the URL (query params or path)
  - `:socket` - survives reconnects via JS client sync
  - `:ephemeral` - socket-only, lost on disconnect (default)

  ## Example

      state :product_id, :integer, from: :url
      state :form_params, :map, from: :ephemeral, default: %{}

  ## Animated State

  State fields can be animated, which adds phase tracking for enter/exit transitions:

      state :panel_open, :boolean, animated: true
      state :product_id, :any, animated: [async: :product, preserve_dom: true]

  This generates additional fields:
  - `{field}_phase` - "idle" | "entering" | "loading" | "visible" | "exiting"
  - `{field}_visible` - calculated boolean, true when phase != "idle"
  - `{field}_animating` - calculated boolean, true during entering/exiting
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
    :animated,
    __spark_metadata__: nil
  ]
end
