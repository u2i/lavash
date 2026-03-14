defmodule Lavash.ExtendErrors do
  @moduledoc """
  Extends auto-generated form field errors with custom error checks.

  Used to add custom validation rules beyond what Ash resource constraints provide.
  The custom errors are merged with Ash-generated errors and visibility is handled
  automatically via JS touched/submitted tracking.

  ## Fields

  - `:field` - The field errors to extend (e.g., :registration_email_errors)
  - `:errors` - List of {condition_rx, message} tuples

  ## Usage

      extend_errors :registration_email_errors do
        error rx(not String.contains?(@registration_params["email"] || "", "@")), "Must contain @"
      end

  This merges the custom error with the auto-generated Ash errors when the condition
  is true (i.e., when the field is invalid).
  """
  defstruct [:field, errors: [], __spark_metadata__: nil]
end

defmodule Lavash.ExtendErrors.Error do
  @moduledoc """
  A single custom error check within extend_errors.

  ## Fields

  - `:condition` - A Lavash.Rx struct that evaluates to true when the error should show
  - `:message` - The error message string
  """
  defstruct [:condition, :message, __spark_metadata__: nil]
end
