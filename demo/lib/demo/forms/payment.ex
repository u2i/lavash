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
end
