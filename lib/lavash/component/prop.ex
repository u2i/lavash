defmodule Lavash.Component.Prop do
  @moduledoc """
  A prop definition for a Lavash component.

  Props are values passed from the parent LiveView or component.
  They are read-only from the component's perspective.
  """
  defstruct [:name, :type, :required, :default, __spark_metadata__: nil]
end
