defmodule Lavash.Parity.Lavash.HandleEventLive do
  @moduledoc """
  Lavash DSL expression of the handle_event parity suite — paired
  with `Lavash.Parity.Vanilla.HandleEventLive`. The same observable
  behaviour, expressed declaratively.

  Where the lavash DSL can already express a vanilla LV pattern,
  the action lives here. Where it can't yet, the action is missing
  and the corresponding parity test carries `@tag :parity_gap` to
  flag the implementation gap.

  ## Out of scope by design

  - `{:reply, payload, socket}` — synchronous reply payloads to JS
    hooks. Rare in practice, always paired with a JS hook, and the
    escape hatch (`run fn socket -> ... end` returning a socket via
    raw Phoenix.LiveView API) covers it cleanly enough. Adding a
    `reply` op to the DSL is deferred until a real use case asks.
  """
  use Lavash.LiveView

  state :count, :integer, default: 0, optimistic: true
  state :last_event, :string, default: nil, optimistic: true
  state :is_admin?, :boolean, default: true, optimistic: true

  actions do
    action :inc do
      set :count, rx(@count + 1)
    end

    action :bump_by, [:amount] do
      set :count, rx(@count + String.to_integer(@amount))
    end

    action :track, [:label] do
      set :last_event, rx(@label)
    end

    action :toggle_admin do
      set :is_admin?, rx(not @is_admin?)
    end

    action :guarded_inc, [], [:is_admin?] do
      set :count, rx(@count + 1)
    end

    action :navigate_demo do
      navigate "/parity/lavash/handle_event_landing"
    end

    action :push_demo do
      push_event("client_pong", %{at: "server"})
    end

    action :patch_demo do
      push_patch("/parity/lavash/handle_event?via=patch")
    end

    action :redirect_demo do
      redirect("/parity/lavash/handle_event_landing")
    end
  end

  template do
    ~H"""
    <div id="handle-event-lavash">
      <p id="count">{@count}</p>
      <p id="last-event">{@last_event || "(none)"}</p>
      <p id="is-admin">{to_string(@is_admin?)}</p>

      <button id="inc" phx-click="inc">+1</button>
      <button id="bump-by" phx-click="bump_by" phx-value-amount="5">+5</button>
      <button id="track" phx-click="track" phx-value-label="howdy">track</button>
      <button id="push-demo" phx-click="push_demo">push</button>
      <button id="patch-demo" phx-click="patch_demo">patch</button>
      <button id="navigate-demo" phx-click="navigate_demo">navigate</button>
      <button id="redirect-demo" phx-click="redirect_demo">redirect</button>
      <button id="toggle-admin" phx-click="toggle_admin">toggle admin</button>
      <button id="guarded-inc" phx-click="guarded_inc">guarded +1</button>
    </div>
    """
  end
end

defmodule Lavash.Parity.Lavash.HandleEventLandingLive do
  use Lavash.LiveView

  template do
    ~H"""
    <div id="handle-event-landing">landed</div>
    """
  end
end
