defmodule Demo.Accounts.User do
  use Ash.Resource,
    domain: Demo.Accounts,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshAuthentication]

  sqlite do
    table "users"
    repo Demo.Repo
  end

  authentication do
    tokens do
      enabled? true
      token_resource Demo.Accounts.Token
      store_all_tokens? true
      require_token_presence_for_authentication? true
      signing_secret fn _, _ ->
        Application.fetch_env(:demo, :token_signing_secret)
      end
    end

    strategies do
      password :password do
        identity_field :email
        sign_in_tokens_enabled? true

        resettable do
          sender Demo.Accounts.Senders.SendPasswordResetEmail
        end
      end
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :email, :ci_string do
      allow_nil? false
      public? true
    end

    attribute :hashed_password, :string do
      allow_nil? false
      sensitive? true
    end

    timestamps()
  end

  actions do
    defaults [:read]
  end

  identities do
    identity :unique_email, [:email]
  end
end
