defmodule Lavash.State.UrlField do
  @moduledoc "A URL-backed state field"
  defstruct [:name, :type, :default, :required, :encode, :decode, __spark_metadata__: nil]
end
