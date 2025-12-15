defmodule Lavash.Actions.Flash do
  @moduledoc """
  A flash message operation within an action.

  Puts a flash message after the action completes successfully.
  """
  defstruct [:kind, :message, __spark_metadata__: nil]
end
