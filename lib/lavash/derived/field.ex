defmodule Lavash.Derived.Field do
  @moduledoc "A derived state field"
  defstruct [:name, :depends_on, :async, :compute, __spark_metadata__: nil]
end
