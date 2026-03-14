defmodule Lavash.DslHelpers do
  @moduledoc """
  Helper functions for use in Lavash DSL declarations.

  These create source references for argument declarations:
  - `state(:field)` - reference a state field
  - `result(:derive)` - reference a derived field's result
  """

  @doc """
  Reference a state field as a dependency source.

  ## Example

      calculate :product, rx(get_product(@product_id))
  """
  def state(field_name) when is_atom(field_name) do
    {:state, field_name}
  end

  @doc """
  Reference a prop field as a dependency source (for components).

  ## Example

      read :product, Product do
        id prop(:product_id)
      end
  """
  def prop(field_name) when is_atom(field_name) do
    {:prop, field_name}
  end

  @doc """
  Reference a derived field's result as a dependency source.

  ## Example

      calculate :doubled, rx(@base_value * 2)
  """
  def result(field_name) when is_atom(field_name) do
    {:result, field_name}
  end
end
