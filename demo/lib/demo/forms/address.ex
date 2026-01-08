defmodule Demo.Forms.Address do
  @moduledoc """
  Ephemeral address resource for checkout form.

  Uses ETS data layer - addresses are stored in memory during the session
  but not persisted to disk. This demonstrates Ash form validation
  for shipping address fields.

  Addresses are scoped by session_id for multi-user demos.
  """
  use Ash.Resource,
    domain: Demo.Forms,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Lavash.Resource]

  lavash do
    notify_on [:session_id]
  end

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id

    attribute :session_id, :string do
      allow_nil? false
      public? true
    end

    attribute :country, :string do
      allow_nil? false
      default "United States"
      public? true
    end

    attribute :first_name, :string do
      allow_nil? false
      public? true
    end

    attribute :last_name, :string do
      allow_nil? false
      public? true
    end

    attribute :company, :string do
      allow_nil? true
      public? true
    end

    attribute :address, :string do
      allow_nil? false
      public? true
    end

    attribute :apartment, :string do
      allow_nil? true
      public? true
    end

    attribute :city, :string do
      allow_nil? false
      public? true
    end

    attribute :state, :string do
      allow_nil? false
      public? true
    end

    attribute :zip, :string do
      allow_nil? false
      public? true
    end

    attribute :phone, :string do
      allow_nil? true
      public? true
    end
  end

  actions do
    defaults [:read, :destroy]

    create :save do
      accept [
        :session_id,
        :country,
        :first_name,
        :last_name,
        :company,
        :address,
        :apartment,
        :city,
        :state,
        :zip,
        :phone
      ]
    end

    read :list do
      argument :session_id, :string, allow_nil?: true

      # Only return addresses if session_id is provided, otherwise empty
      filter expr(
        if is_nil(^arg(:session_id)) do
          false
        else
          session_id == ^arg(:session_id)
        end
      )
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
