defmodule Demo.Validations.EmailFormat do
  @moduledoc """
  Custom Ash validation that checks email format using a regex.

  This validation cannot be transpiled to client-side JS by Lavash's
  constraint transpiler, so it runs server-side only. This makes it
  a good example of server-only validation in the validation demo.
  """
  use Ash.Resource.Validation

  @email_regex ~r/^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/

  @impl true
  def validate(changeset, opts, _context) do
    attribute = opts[:attribute] || :email

    case Ash.Changeset.get_attribute(changeset, attribute) do
      nil ->
        :ok

      value when is_binary(value) ->
        if String.match?(value, @email_regex) do
          :ok
        else
          {:error, field: attribute, message: "must be a valid email address"}
        end

      _ ->
        :ok
    end
  end
end
