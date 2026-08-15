defmodule Demo.Cart.Cart do
  use Ash.Resource,
    domain: Demo.Cart,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "carts"
    repo(Demo.Repo)
  end

  attributes do
    uuid_primary_key :id
    timestamps()
  end

  relationships do
    belongs_to :user, Demo.Accounts.User, allow_nil?: false
    has_many :items, Demo.Cart.CartItem
  end

  # Note: SQLite doesn't support aggregates on has_many, calculate these in LiveView

  actions do
    defaults [:read]

    destroy :destroy do
      primary? true
      # Items go first — SQLite enforces the FK.
      change cascade_destroy(:items, after_action?: false, return_notifications?: false)
    end

    create :create do
      accept []
      change relate_actor(:user)
    end

    read :for_user do
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id))
    end
  end
end
