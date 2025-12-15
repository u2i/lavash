defmodule Lavash.Derived.Field do
  @moduledoc """
  A derived state field.

  Derived fields compute values from inputs or other derived fields.
  Dependencies are declared via `argument` entities using Reactor-style syntax.
  """
  defstruct [
    :name,
    :async,
    :run,
    arguments: [],
    # Legacy field - computed from arguments for backwards compatibility
    depends_on: [],
    # Legacy field - wrapped version of run
    compute: nil,
    __spark_metadata__: nil
  ]
end
