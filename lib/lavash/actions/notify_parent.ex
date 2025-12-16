defmodule Lavash.Actions.NotifyParent do
  @moduledoc """
  A notify parent operation within a component action.

  Sends an event to the parent LiveView after the action completes.
  The event can be a prop name (string) that references a prop holding the event name,
  or a literal atom event name.
  """
  defstruct [:event, __spark_metadata__: nil]
end
