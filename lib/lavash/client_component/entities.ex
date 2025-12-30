defmodule Lavash.ClientComponent.Bind do
  @moduledoc "A binding that connects component state to parent state."
  defstruct [:name, :type, :__spark_metadata__]
end

defmodule Lavash.ClientComponent.Prop do
  @moduledoc "A prop passed from the parent component."
  defstruct [:name, :type, :required, :default, :__spark_metadata__]
end

defmodule Lavash.ClientComponent.Calculate do
  @moduledoc "A calculated field that runs on both client and server."
  defstruct [:name, :expr, :__spark_metadata__]
end

defmodule Lavash.ClientComponent.OptimisticAction do
  @moduledoc """
  An optimistic action that generates both client JS and server handlers.

  The `run` function is compiled to both Elixir and JavaScript.
  """
  defstruct [:name, :field, :run, :run_source, :validate, :validate_source, :max, :__spark_metadata__]
end

defmodule Lavash.ClientComponent.Template do
  @moduledoc "The component template, compiled to both HEEx and JS."
  defstruct [:source, :__spark_metadata__]
end
