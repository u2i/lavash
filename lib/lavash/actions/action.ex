defmodule Lavash.Actions.Action do
  @moduledoc "An action that transforms state"
  defstruct [:name, :params, :when, :sets, :updates, :effects, __spark_metadata__: nil]
end
