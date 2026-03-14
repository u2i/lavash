defmodule Lavash.Component.Render do
  @moduledoc """
  A render function for LiveViews and Components.

  The render function receives assigns and returns HEEx markup.
  Used in place of string-based templates for better editor support.

  ## Fields

  - `:template` - The render function (fn assigns -> ~H"..." end)

  ## Usage

      render fn assigns ->
        ~H\"""
        <div>{@count}</div>
        \"""
      end
  """
  defstruct [:template, __spark_metadata__: nil]
end
