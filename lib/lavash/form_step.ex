defmodule Lavash.FormStep do
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

      derive :form do
        argument :data, result(:product)
        argument :params, input(:form_params)
        run fn %{data: data, params: params}, _ ->
          if data && data.id do
            AshPhoenix.Form.for_update(data, :update, params: params)
          else
            AshPhoenix.Form.for_create(Product, :create, params: params)
          end
        end
      end
  """

  defstruct [
    :name,
    :resource,
    :data,
    :params,
    :create,
    :update,
    __spark_metadata__: nil
  ]
end
