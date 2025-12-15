defmodule Lavash.Actions.Navigate do
  @moduledoc """
  A navigation operation within an action.

  Navigates to a URL after the action completes successfully.
  """
  defstruct [:to, __spark_metadata__: nil]
end
