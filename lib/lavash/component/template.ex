defmodule Lavash.Component.Template do
  @moduledoc """
  DEPRECATED: Use Lavash.Component.Render instead.

  A component template that compiles to both HEEx and JS.

  The template source is parsed and transformed during compilation
  to generate both server-side HEEx rendering and client-side
  JavaScript for optimistic updates.
  """
  defstruct [:source, :deprecated_name, __spark_metadata__: nil]
end
