defmodule Lavash.State.FormField do
  @moduledoc """
  Represents a form binding that syncs DOM form params to ephemeral state.

  Form fields:
  - Are ephemeral (socket-only, not in URL)
  - Auto-update when events contain matching form params
  - Default to an empty map
  """

  defstruct [:name, :from, default: %{}, __spark_metadata__: nil]
end
