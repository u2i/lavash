# Entity structs for ClientComponent (component-specific ones only)
# Shared entities are in Lavash.Component.*

defmodule Lavash.ClientComponent.Bind do
  @moduledoc "A binding that connects component state to parent state."
  defstruct [:name, :type, __spark_metadata__: nil]
end

defmodule Lavash.ClientComponent.Calculate do
  @moduledoc "A calculated field that runs on both client and server."
  defstruct [:name, :expr, __spark_metadata__: nil]
end
