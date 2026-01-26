defmodule Demo.Forms.Account do
  @moduledoc """
  Ephemeral account resource for the validation demo.

  Demonstrates both client-evaluable and server-only validations:

  - `username`: required, min 3, max 20 chars (all transpiled to client JS)
  - `email`: required (client), custom format validation (server-only)
  - `password`: required, min 8 chars (all transpiled to client JS)

  The custom email format validation uses `Demo.Validations.EmailFormat`,
  which is an Ash validation module that cannot be transpiled to JS.
  It runs on the server after a debounced round-trip.
  """
  use Ash.Resource,
    domain: Demo.Forms,
    data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id

    attribute :username, :string do
      allow_nil? false
      public? true
      constraints min_length: 3, max_length: 20
    end

    attribute :email, :string do
      allow_nil? false
      public? true
    end

    attribute :password, :string do
      allow_nil? false
      public? true
      constraints min_length: 8
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create_account do
      accept [:username, :email, :password]
    end
  end

  validations do
    validate present(:username), message: "Username is required"
    validate present(:email), message: "Email is required"
    validate present(:password), message: "Password is required"

    validate string_length(:username, min: 3, max: 20),
      message: "Username must be 3-20 characters"

    validate string_length(:password, min: 8),
      message: "Password must be at least 8 characters"

    # Server-only: custom validation module that can't be transpiled to JS
    validate {Demo.Validations.EmailFormat, attribute: :email}
  end
end
