defmodule Demo.Orders.Address do
  use Ash.Resource,
    domain: Demo.Orders,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "addresses"
    repo Demo.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :label, :string do
      allow_nil? true
      public? true
    end

    attribute :first_name, :string, allow_nil?: false, public?: true
    attribute :last_name, :string, allow_nil?: false, public?: true
    attribute :company, :string, allow_nil?: true, public?: true
    attribute :address, :string, allow_nil?: false, public?: true
    attribute :apartment, :string, allow_nil?: true, public?: true
    attribute :city, :string, allow_nil?: false, public?: true
    attribute :state, :string, allow_nil?: false, public?: true
    attribute :zip, :string, allow_nil?: false, public?: true
    attribute :country, :string, allow_nil?: false, default: "United States", public?: true
    attribute :phone, :string, allow_nil?: true, public?: true

    timestamps()
  end

  relationships do
    belongs_to :user, Demo.Accounts.User, allow_nil?: false
  end

  actions do
    defaults [:read, :destroy]

    create :save do
      accept [
        :label, :first_name, :last_name, :company, :address,
        :apartment, :city, :state, :zip, :country, :phone
      ]

      change relate_actor(:user)
    end

    update :update do
      accept [
        :label, :first_name, :last_name, :company, :address,
        :apartment, :city, :state, :zip, :country, :phone
      ]
    end

    read :for_user do
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id))
      prepare build(sort: [inserted_at: :desc])
    end
  end

  validations do
    validate present(:first_name), message: "Enter a first name"
    validate present(:last_name), message: "Enter a last name"
    validate present(:address), message: "Enter an address"
    validate present(:city), message: "Enter a city"
    validate present(:state), message: "Enter a state"
    validate present(:zip), message: "Enter a ZIP code"
  end
end
