defmodule Lavash.Rx.Functions do
  @moduledoc """
  Module for defining reusable reactive functions that can be imported into LiveViews.

  ## Usage

  Create a module with `defrx` functions:

      defmodule MyApp.Validators do
        use Lavash.Rx.Functions

        defrx valid_email?(email) do
          String.length(email) > 0 && String.contains?(email, "@")
        end

        defrx valid_phone?(phone) do
          String.match?(phone, ~r/^\\d{10}$/)
        end
      end

  Then import them in your LiveView:

      defmodule MyAppWeb.UserLive do
        use Lavash.LiveView
        import Lavash.Rx
        import_rx MyApp.Validators

        calculate :email_valid, rx(valid_email?(@email))
        calculate :phone_valid, rx(valid_phone?(@phone))
      end

  ## How it works

  When you `use Lavash.Rx.Functions`:

  1. The `defrx` macro becomes available for defining functions
  2. At compile time, all `defrx` definitions are collected
  3. A `__defrx_definitions__/0` function is generated that returns all definitions
  4. Other modules can import these definitions using `import_rx`

  ## Important constraints

  - `defrx` function bodies must be single expressions
  - No intermediate variable assignments (e.g., `x = 1` is not allowed)
  - All code must be transpilable to JavaScript (see `Lavash.Rx.Transpiler`)

  ## Example with nested functions

  You can call other defrx functions from within a defrx body:

      defmodule MyApp.CardValidators do
        use Lavash.Rx.Functions

        defrx expected_length(is_amex) do
          if(is_amex, do: 15, else: 16)
        end

        defrx valid_card_number?(digits, is_amex) do
          String.match?(digits, ~r/^\\d+$/) &&
            String.length(digits) == expected_length(is_amex)
        end
      end
  """

  defmacro __using__(_opts) do
    quote do
      import Lavash.Rx, only: [defrx: 2]

      Module.register_attribute(__MODULE__, :lavash_defrx, accumulate: true)

      @before_compile Lavash.Rx.Functions
    end
  end

  defmacro __before_compile__(env) do
    defrx_defs = Module.get_attribute(env.module, :lavash_defrx) || []

    quote do
      @doc """
      Returns all defrx definitions from this module.

      Format: `[{name, arity, params, body_ast, body_source}, ...]`
      """
      def __defrx_definitions__ do
        unquote(Macro.escape(defrx_defs))
      end
    end
  end
end
