defmodule Lavash.Form.Step do
  @moduledoc """
  DSL entity for a form step that creates an AshPhoenix.Form.

  Expands to a derived field that creates the appropriate form
  based on whether data is nil (create) or a record (update).

  ## Example

      form :form, Product do
        data result(:product)
        params input(:form_params)
      end

  This is equivalent to:

      calculate :form, rx(build_form(@product, @form_params))
  """

  defstruct [
    :name,
    :resource,
    :data,
    :params,
    :create,
    :update,
    skip_constraints: [],
    __spark_metadata__: nil
  ]
end
