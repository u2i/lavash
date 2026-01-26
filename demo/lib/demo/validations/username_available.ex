defmodule Demo.Validations.UsernameAvailable do
  @moduledoc """
  Custom Ash validation that checks username availability.

  Simulates a database uniqueness check with a hardcoded list.
  Cannot be transpiled to JS since it represents a server-side
  data lookup.
  """
  use Ash.Resource.Validation

  @taken_usernames ~w(admin root test user demo moderator)

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :username) do
      nil ->
        :ok

      value when is_binary(value) ->
        if String.downcase(value) in @taken_usernames do
          {:error, field: :username, message: "is already taken"}
        else
          :ok
        end

      _ ->
        :ok
    end
  end
end
