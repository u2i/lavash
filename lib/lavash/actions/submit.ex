defmodule Lavash.Actions.Submit do
  @moduledoc """
  An async form submission within an action.

  Submits a form and handles success/error branching:
  - On success: triggers the `on_success` action if specified, then continues
  - On error: triggers the `on_error` action instead

  Example:
      action :save do
        set :submitting, true
        submit :form, on_success: :after_save, on_error: :save_failed
        flash :info, "Saved!"
      end

      action :after_save do
        set :editing_product_id, nil
        set :submitting, false
      end

      action :save_failed do
        set :submitting, false
      end
  """
  defstruct [:field, :on_success, :on_error, __spark_metadata__: nil]
end
