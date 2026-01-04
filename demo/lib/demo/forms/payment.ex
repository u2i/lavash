defmodule Demo.Forms.Payment do
  @moduledoc """
  Ephemeral payment resource for checkout form validation.

  Uses ETS data layer - forms are stored in memory during the session
  but not persisted to disk. This demonstrates Ash form validation
  for credit card fields.

  ## Validation Messages

  Each field has two possible error messages:
  - Required: "Enter a/an X" (when empty)
  - Invalid: "Enter a valid X" (when present but invalid)

  Client-side validation uses `valid_card_number?/1` which checks:
  - Card type detection from prefix
  - Correct length for card type (15 for Amex, 16 for others)
  - Luhn checksum
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
    end

    attribute :expiry, :string do
      allow_nil? false
      public? true
    end

    attribute :cvv, :string do
      allow_nil? false
      public? true
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
      # Client-side validation handles card number, expiry, and CVV via extend_errors
      # Server-side only validates required fields (from validations block)
    end
  end

  validations do
    # Required field messages
    validate present(:card_number), message: "Enter a card number"
    validate present(:expiry), message: "Enter an expiration date"
    validate present(:cvv), message: "Enter the security code"
    validate present(:name), message: "Enter your name exactly as it's written on your card"

    # Name length
    validate string_length(:name, min: 2),
      message: "Enter your name exactly as it's written on your card"
  end
end

