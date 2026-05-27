defmodule Demo.Orders.Order do
  use Ash.Resource,
    domain: Demo.Orders,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "orders"
    repo Demo.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :status, :atom do
      allow_nil? false
      default :pending
      constraints one_of: [:pending, :paid, :shipped, :delivered, :cancelled]
    end

    attribute :subtotal, :decimal, allow_nil?: false
    attribute :tax, :decimal, allow_nil?: false
    attribute :shipping, :decimal, allow_nil?: false
    attribute :total, :decimal, allow_nil?: false

    attribute :payment_method, :string, default: "card"
    attribute :card_last_four, :string

    timestamps()
  end

  relationships do
    belongs_to :user, Demo.Accounts.User, allow_nil?: false
    belongs_to :shipping_address, Demo.Orders.Address
    belongs_to :billing_address, Demo.Orders.Address
    has_many :items, Demo.Orders.OrderItem
  end

  actions do
    defaults [:read, :destroy]

    create :place do
      accept [:subtotal, :tax, :shipping, :total, :payment_method, :card_last_four]

      argument :cart_id, :uuid, allow_nil?: false
      argument :shipping_address_id, :uuid
      argument :billing_address_id, :uuid

      change relate_actor(:user)
      change manage_relationship(:shipping_address_id, :shipping_address, type: :append)
      change manage_relationship(:billing_address_id, :billing_address, type: :append)

      # Copy cart items into order items
      change fn changeset, context ->
        Ash.Changeset.after_action(changeset, fn _changeset, order ->
          cart_id = Ash.Changeset.get_argument(changeset, :cart_id)

          cart_items =
            Demo.Cart.CartItem
            |> Ash.ActionInput.for_action(:for_cart, %{cart_id: cart_id})
            |> Ash.read!()

          Enum.each(cart_items, fn item ->
            Demo.Orders.OrderItem
            |> Ash.Changeset.for_create(:create, %{
              order_id: order.id,
              product_id: item.product_id,
              product_name: item.product.name,
              quantity: item.quantity,
              unit_price: item.unit_price
            })
            |> Ash.create!()
          end)

          # Clear the cart
          cart_items
          |> Enum.each(&Ash.destroy!/1)

          {:ok, order}
        end)
      end
    end

    read :for_user do
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id))
      prepare build(sort: [inserted_at: :desc])
    end

    # All orders, newest first. Used by the admin order-management
    # screens. The optional `:status` argument filters by status.
    read :all_for_admin do
      argument :status, :atom, allow_nil?: true
      filter expr(is_nil(^arg(:status)) or status == ^arg(:status))
      prepare build(sort: [inserted_at: :desc], load: [:user])
    end

    read :admin_detail do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
      prepare build(load: [:user, :items, shipping_address: [], billing_address: []])
    end

    # Loads a single order belonging to the given user, with line
    # items + shipping/billing addresses pre-fetched. Returns nil if
    # the order doesn't exist or doesn't belong to the user — used
    # by the customer order-detail page to gate access.
    read :detail_for_user do
      argument :id, :uuid, allow_nil?: false
      argument :user_id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id) and user_id == ^arg(:user_id))

      prepare build(
                load: [
                  :items,
                  shipping_address: [],
                  billing_address: []
                ]
              )
    end

    update :cancel do
      change set_attribute(:status, :cancelled)

      validate fn changeset, _ ->
        case Ash.Changeset.get_data(changeset, :status) do
          :pending -> :ok
          :paid -> :ok
          status -> {:error, "Cannot cancel an order in status #{status}"}
        end
      end
    end

    update :update_status do
      accept [:status]
    end
  end
end
