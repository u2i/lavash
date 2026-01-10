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
      allow_nil? true
      public? true
    end

    attribute :hashed_password, :string do
      allow_nil? true
      sensitive? true
    end

    attribute :anonymous, :boolean do
      default true
      allow_nil? false
      public? true
    end

    timestamps()
  end

  actions do
    defaults [:read]

    create :create_anonymous do
      accept []
      change set_attribute(:anonymous, true)

      # Generate token manually (can't use GenerateTokenChange as there's no strategy)
      change after_action(fn _changeset, user, _context ->
        {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user, %{"purpose" => "user"})
        {:ok, Ash.Resource.put_metadata(user, :token, token)}
      end)
    end

    update :register do
      accept [:email]
      argument :password, :string, allow_nil?: false, sensitive?: true
      argument :password_confirmation, :string, allow_nil?: false, sensitive?: true

      validate confirm(:password, :password_confirmation)

      change set_attribute(:anonymous, false)
      change AshAuthentication.Strategy.Password.HashPasswordChange
      change AshAuthentication.GenerateTokenChange
    end
  end

  identities do
    identity :unique_email, [:email], where: expr(not is_nil(email))
  end
end
