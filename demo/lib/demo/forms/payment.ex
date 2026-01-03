defmodule Demo.Forms.Payment do
  @moduledoc """
  Ephemeral payment resource for checkout form validation.

  Uses ETS data layer - forms are stored in memory during the session
  but not persisted to disk. This demonstrates Ash form validation
  for credit card fields.
  """
  use Ash.Resource,
    domain: Demo.Forms,
    data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id

    attribute :card_number, :string do
      allow_nil? false
      public? true
      constraints min_length: 15, max_length: 16
    end

    attribute :expiry, :string do
      allow_nil? false
      public? true
      constraints min_length: 4, max_length: 5
    end

    attribute :cvv, :string do
      allow_nil? false
      public? true
      constraints min_length: 3, max_length: 4
    end

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 2
    end
  end

  actions do
    defaults [:read, :destroy]

    create :pay do
      accept [:card_number, :expiry, :cvv, :name]
    end
  end

  validations do
    validate present(:card_number), message: "Enter a card number"
    validate present(:expiry), message: "Enter an expiration date"
    validate present(:cvv), message: "Enter the security code"
    validate present(:name), message: "Enter the name on your card"

    validate string_length(:card_number, min: 15, max: 16),
      message: "Card number should be 15-16 digits"

    validate string_length(:expiry, min: 4, max: 5),
      message: "Enter a valid expiration (MM/YY)"

    validate string_length(:cvv, min: 3, max: 4),
      message: "CVV should be 3-4 digits"

    validate string_length(:name, min: 2),
      message: "Enter your full name"
  end
end
