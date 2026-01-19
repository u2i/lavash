defmodule Lavash.Actions.Action do
  @moduledoc """
  An action that transforms state in response to events.

  Actions can contain:
  - `set` - Set a state field to a value using @field syntax
  - `run` - Execute a function that returns updated assigns
  - `update` - (deprecated) Update a state field with a function
  - `effect` - Run a side effect
  - `submit` - Submit a form (async, with on_error branching)
  - `navigate` - Navigate to a URL on success
  - `flash` - Show a flash message on success
  - `invoke` - Invoke an action on a child component
  """
  defstruct [
    :name,
    :params,
    :reads,
    :when,
    :sets,
    :runs,
    :updates,
    :effects,
    :submits,
    :navigates,
    :flashes,
    :notify_parents,
    :invokes,
    __spark_metadata__: nil
  ]
end
