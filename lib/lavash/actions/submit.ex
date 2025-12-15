defmodule Lavash.Actions.Submit do
  @moduledoc """
  An async form submission within an action.

  Submits a form and handles success/error branching:
  - On success: continues with remaining action operations (navigate, flash, etc.)
  - On error: triggers the `on_error` action instead

  Example:
      action :save do
        set :submitting, true
        submit :form, on_error: :save_failed
        navigate "/products"
        flash :info, "Saved!"
      end

      action :save_failed do
        set :submitting, false
      end
  """
  defstruct [:field, :on_error, __spark_metadata__: nil]
end
