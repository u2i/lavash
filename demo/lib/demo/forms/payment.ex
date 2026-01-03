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

    # Card fields - constraints apply server-side, client-side uses extend_errors
    # with card-type-specific messages via skip_constraints in the form DSL
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
    # Required field messages (these override the generic "is required")
    validate present(:card_number), message: "Enter a card number"
    validate present(:expiry), message: "Enter an expiration date"
    validate present(:cvv), message: "Enter the security code"
    validate present(:name), message: "Enter the name on your card"

    # Name length - no card-type-specific override needed
    validate string_length(:name, min: 2),
      message: "Enter your full name"

    # Note: card_number, expiry, and cvv constraints are applied server-side,
    # but skipped client-side via `skip_constraints` in the form DSL.
    # The LiveView uses extend_errors for card-type-specific messages
    # (e.g., "Amex requires 15 digits" vs "Must be 16 digits")
  end
end
