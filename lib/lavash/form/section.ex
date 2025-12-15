defmodule Lavash.Form.Section do
  @moduledoc """
  Struct representing a top-level form declaration.

  A form encapsulates the full lifecycle of editing an Ash resource:
  - Captures params from events (implicitly creates ephemeral state)
  - Depends on a loaded record via argument declarations
  - Builds changesets for create/update
  - Provides Phoenix.HTML.Form for rendering
  - Supports submission via actions

  Example:
      form :form, resource: Product do
        argument :record, result(:product)
      end
  """

  defstruct [
    :name,
    :resource,
    :from,
    arguments: [],
    create: :create,
    update: :update,
    __spark_metadata__: nil
  ]
end
