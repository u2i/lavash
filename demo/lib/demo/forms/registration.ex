defmodule Demo.Forms.Registration do
  @moduledoc """
  Ephemeral registration resource for form validation demos.

  Uses ETS data layer - forms are stored in memory during the session
  but not persisted to disk. This demonstrates Ash form validation
  without requiring database setup.
  """
  use Ash.Resource,
    domain: Demo.Forms,
    data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 2
    end

    attribute :email, :string do
      allow_nil? false
      public? true
    end

    attribute :age, :integer do
      allow_nil? false
      public? true
      constraints min: 18
    end
  end

  # Note: Email format validation is handled by rx() calculations on client-side
  # and could use a custom validation module for server-side if needed

  actions do
    defaults [:read, :destroy]

    create :register do
      accept [:name, :email, :age]
    end

    update :update do
      accept [:name, :email, :age]
    end
  end
end
