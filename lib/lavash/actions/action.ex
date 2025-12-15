defmodule Lavash.Actions.Action do
  @moduledoc """
  An action that transforms state in response to events.

  Actions can contain:
  - `set` - Set a state field to a value
  - `update` - Update a state field with a function
  - `effect` - Run a side effect
  - `submit` - Submit a form (async, with on_error branching)
  - `navigate` - Navigate to a URL on success
  - `flash` - Show a flash message on success
  """
  defstruct [:name, :params, :when, :sets, :updates, :effects, :submits, :navigates, :flashes, __spark_metadata__: nil]
end
