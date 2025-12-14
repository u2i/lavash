defmodule Lavash.State.SocketField do
  @moduledoc """
  A socket state field.

  Socket fields survive reconnects via JS client sync but are lost on page refresh.
  They don't appear in the URL.
  """
  defstruct [:name, :type, :default, __spark_metadata__: nil]
end
