defmodule Lavash.Form.Section do
  @moduledoc """
  Struct representing a top-level form declaration.

  A form encapsulates the full lifecycle of editing an Ash resource:
  - Captures params from events (implicitly creates ephemeral state)
  - Depends on a loaded record (from derived state)
  - Builds changesets for create/update
  - Provides Phoenix.HTML.Form for rendering
  - Supports submission via actions
  """

  defstruct [
    :name,
    :resource,
    :load,
    :from,
    create: :create,
    update: :update,
    __spark_metadata__: nil
  ]
end
