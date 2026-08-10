defmodule Lavash.Actions.Remove do
  @moduledoc """
  Keyed removal of a `client_state` projection row.

      action :remove, [:id] do
        remove :items
      end

  Client-side (transpiled) the row whose key matches the action's
  param is dropped instantly. Server-side the record is fetched by
  the projection's key and destroyed (via the optional `action:`,
  defaulting to the resource's primary destroy), the resource is
  broadcast, and the backing read re-reads in the same event.
  """
  defstruct [
    :field,
    :action,
    __spark_metadata__: nil
  ]
end
