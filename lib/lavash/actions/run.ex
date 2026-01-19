defmodule Lavash.Actions.Run do
  @moduledoc """
  Executes a function that returns updated assigns.

  ## Server-only (plain function)

  The function receives assigns (state + params merged) and should use
  `assign/3` to update fields:

      run fn assigns ->
        assigns
        |> assign(:status, :processing)
        |> assign(:submitted_at, DateTime.utc_now())
      end

  ## Transpilable (with reads)

  Add `reads` to declare state dependencies, enabling JavaScript transpilation:

      run [:subtotal, :discount_rate], fn assigns ->
        discount = assigns.subtotal * assigns.discount_rate
        final = assigns.subtotal - discount

        assigns
        |> assign(:discount_amount, discount)
        |> assign(:total, final)
      end

  ## Fields

  - `:fun` - The function AST (quoted), compiled at runtime for server-side execution
  """
  defstruct [:fun, __spark_metadata__: nil]
end
