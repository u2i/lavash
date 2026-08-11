defmodule Lavash.Test.Magic.TriggerFlyover do
  @moduledoc """
  Fixture: overlay with a `template_trigger` whose badge counts a
  `client_state` projection, plus an `append` action the HOST invokes —
  exercising the trigger slot, the projection-backed optimistic badge,
  and `invoke`'s client half (cross-hook prediction).
  """
  use Lavash.Component, extensions: [Lavash.Overlay.Flyover.Dsl]

  alias Lavash.Test.Magic.ClientCart.Item

  flyover do
    open_field :open
  end

  prop :cart_id, :string, required: true

  read :badge_source, Item, :for_cart do
    argument :cart_id, prop(:cart_id)
    async false

    client_state :badge_items do
      key :id
      fields [:id, :quantity]
    end
  end

  calculate :badge_count,
            rx(Enum.reduce(@badge_items || [], 0, fn item, acc -> acc + item.quantity end))

  actions do
    action :add_item, [:name, :qty] do
      append :badge_items,
             :create,
             rx(%{cart_id: @cart_id, name: @name, quantity: @qty, unit_price: "1.00"})
    end
  end

  template_trigger do
    ~H"""
    <span id="trigger-content" class="btn">Cart (<span id="badge-count">{@badge_count}</span>)</span>
    """
  end

  template do
    ~H"""
    <div id="flyover-body">
      <p>Flyover content</p>
    </div>
    """
  end
end

defmodule Lavash.Test.Magic.TriggerFlyoverHostLive do
  @moduledoc """
  Host for the trigger-flyover fixture. Its `add_remote` action
  invokes the flyover's `append` — server via send_update, client via
  invoke's optimistic half — so the badge bumps in the same tick.

  The flyover's open state is BOUND to the host's `:fly_open` — the
  geometry of the rapid open/close/open bounce (parent echoes of
  earlier cycles arriving during a later open must not close it).
  """
  use Lavash.LiveView
  import Lavash.LiveView.Helpers, only: [lavash_component: 1]

  state :cart_id, :string, from: :url
  state :fly_open, :any, from: :ephemeral, default: nil, optimistic: true
  state :add_qty, :integer, from: :ephemeral, default: 2, optimistic: true

  actions do
    action :add_remote do
      invoke "trig-fly", :add_item,
        module: Lavash.Test.Magic.TriggerFlyover,
        params: [name: "Widget", qty: {:state, :add_qty}]
    end
  end

  template do
    ~H"""
    <div>
      <h1>Trigger flyover host</h1>
      <button id="add-remote" phx-click="add_remote">add remote</button>
      <.lavash_component
        module={Lavash.Test.Magic.TriggerFlyover}
        id="trig-fly"
        cart_id={@cart_id}
        open={@fly_open}
        bind={[open: :fly_open]}
      />
    </div>
    """
  end
end
