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

      derive :product do
        argument :id, state(:product_id)
        run fn %{id: id}, _ -> Catalog.get_product(id) end
      end
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

      derive :doubled do
        argument :base, result(:base_value)
        run fn %{base: b}, _ -> b * 2 end
      end
  """
  def result(field_name) when is_atom(field_name) do
    {:result, field_name}
  end
end
