defmodule Lavash.Test.Magic.TriggerFlyover do
  @moduledoc """
  Fixture: overlay with a `template_trigger` — the trigger (with an
  optimistic count badge) renders outside the panel chrome, wired to
  open the flyover optimistically with dialog ARIA.
  """
  use Lavash.Component, extensions: [Lavash.Overlay.Flyover.Dsl]

  flyover do
    open_field :open
  end

  state :count, :integer, from: :ephemeral, default: 2, optimistic: true

  actions do
    action :bump do
      set :count, rx(@count + 1)
    end
  end

  template_trigger do
    ~H"""
    <span id="trigger-content" class="btn">Cart ({@count})</span>
    """
  end

  template do
    ~H"""
    <div id="flyover-body">
      <p>Flyover content</p>
      <button id="bump" phx-click="bump">bump</button>
    </div>
    """
  end
end

defmodule Lavash.Test.Magic.TriggerFlyoverHostLive do
  @moduledoc "Host for the trigger-flyover fixture."
  use Lavash.LiveView

  def render(assigns) do
    ~H"""
    <div>
      <h1>Trigger flyover host</h1>
      <.live_component module={Lavash.Test.Magic.TriggerFlyover} id="trig-fly" />
    </div>
    """
  end
end
