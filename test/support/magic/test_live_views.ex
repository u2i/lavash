defmodule Lavash.Test.Magic.CounterLive do
  @moduledoc """
  Test fixture: Simple counter with URL state.
  """
  use Lavash.LiveView

  state :count, :integer, from: :url, default: 0
  state :multiplier, :integer, from: :ephemeral, default: 2

  calculate :doubled, rx(@count * @multiplier)

  actions do
    action :increment do
      set :count, rx(@count + 1)
    end

    action :decrement do
      set :count, rx(@count - 1)
    end

    action :set_count, [:value] do
      set :count, &String.to_integer(&1.params.value)
    end

    action :reset do
      set :count, 0
    end
  end

  def render(assigns) do
    ~H"""
    <div>
      <span id="count">{@count}</span>
      <span id="doubled">{@doubled}</span>
      <button id="inc" phx-click="increment">+</button>
      <button id="dec" phx-click="decrement">-</button>
      <button id="reset" phx-click="reset">Reset</button>
    </div>
    """
  end
end

defmodule Lavash.Test.Magic.ChainedDerivedLive do
  @moduledoc """
  Test fixture: Derived fields that depend on other derived fields.
  count → doubled → quadrupled
  """
  use Lavash.LiveView

  state :count, :integer, from: :url, default: 1

  calculate :doubled, rx(@count * 2)
  calculate :quadrupled, rx(@doubled * 2)
  calculate :octupled, rx(@quadrupled * 2)

  actions do
    action :increment do
      set :count, rx(@count + 1)
    end

    action :set_count, [:value] do
      set :count, &String.to_integer(&1.params.value)
    end
  end

  def render(assigns) do
    ~H"""
    <div>
      <span id="count">{@count}</span>
      <span id="doubled">{@doubled}</span>
      <span id="quadrupled">{@quadrupled}</span>
      <span id="octupled">{@octupled}</span>
      <button id="inc" phx-click="increment">+</button>
    </div>
    """
  end
end

defmodule Lavash.Test.Magic.ChainedEphemeralLive do
  @moduledoc """
  Test fixture: Chained derived fields from ephemeral state.
  This tests recompute_dirty (not recompute_all) since ephemeral
  state changes don't trigger handle_params.
  """
  use Lavash.LiveView

  state :base, :integer, from: :ephemeral, default: 1

  calculate :doubled, rx(@base * 2)
  calculate :quadrupled, rx(@doubled * 2)
  calculate :octupled, rx(@quadrupled * 2)

  actions do
    action :increment do
      set :base, rx(@base + 1)
    end
  end

  def render(assigns) do
    ~H"""
    <div>
      <span id="base">{@base}</span>
      <span id="doubled">{@doubled}</span>
      <span id="quadrupled">{@quadrupled}</span>
      <span id="octupled">{@octupled}</span>
      <button id="inc" phx-click="increment">+</button>
    </div>
    """
  end
end

defmodule Lavash.Test.Magic.AsyncChainLive do
  @moduledoc """
  Test fixture: Async derived fields in a chain.
  count → async_doubled → sync_quadrupled
  """
  use Lavash.LiveView

  state :count, :integer, from: :url, default: 1

  calculate :doubled, rx(slow_double(@count)), async: true
  calculate :quadrupled, rx(@doubled * 2)

  def slow_double(c) do
    Process.sleep(50)
    c * 2
  end

  actions do
    action :increment do
      set :count, rx(@count + 1)
    end
  end

  def render(assigns) do
    ~H"""
    <div>
      <span id="count">{@count}</span>
      <span id="doubled">
        <%= case @doubled do %>
          <% %Phoenix.LiveView.AsyncResult{loading: loading} when loading != nil -> %>loading
          <% %Phoenix.LiveView.AsyncResult{ok?: true, result: val} -> %>{val}
          <% val -> %>{val}
        <% end %>
      </span>
      <span id="quadrupled">
        <%= case @quadrupled do %>
          <% %Phoenix.LiveView.AsyncResult{loading: loading} when loading != nil -> %>loading
          <% %Phoenix.LiveView.AsyncResult{ok?: true, result: val} -> %>{val}
          <% val -> %>{val}
        <% end %>
      </span>
      <button id="inc" phx-click="increment">+</button>
    </div>
    """
  end
end

defmodule Lavash.Test.Magic.PathParamLive do
  @moduledoc """
  Test fixture: LiveView with path parameter as URL state.
  Used to test updating path params via push_patch.
  """
  use Lavash.LiveView

  state :product_id, :integer, from: :url
  state :tab, :string, from: :url, default: "details"

  actions do
    action :set_product, [:id] do
      set :product_id, &String.to_integer(&1.params.id)
    end

    action :set_tab, [:name] do
      set :tab, & &1.params.name
    end

    action :next_product do
      set :product_id, rx(@product_id + 1)
    end
  end

  def render(assigns) do
    ~H"""
    <div>
      <span id="product-id">{@product_id}</span>
      <span id="tab">{@tab}</span>
      <button id="next-product" phx-click="next_product">Next Product</button>
      <button id="set-reviews" phx-click="set_tab" phx-value-name="reviews">Reviews</button>
    </div>
    """
  end
end

defmodule Lavash.Test.Magic.TypedLive do
  @moduledoc """
  Test fixture: LiveView with various typed URL fields.
  """
  use Lavash.LiveView

  state :page, :integer, from: :url, default: 1
  state :active, :boolean, from: :url, default: false
  state :query, :string, from: :url, default: ""
  state :tags, {:array, :string}, from: :url, default: []

  actions do
    action :set_page, [:value] do
      set :page, &String.to_integer(&1.params.value)
    end

    action :toggle_active do
      set :active, rx(not @active)
    end

    action :set_query, [:value] do
      set :query, & &1.params.value
    end
  end

  def render(assigns) do
    ~H"""
    <div>
      <span id="page">{@page}</span>
      <span id="active">{@active}</span>
      <span id="query">{@query}</span>
      <span id="tags">{Enum.join(@tags, ",")}</span>
      <button id="next-page" phx-click="set_page" phx-value-value={@page + 1}>Next</button>
      <button id="toggle" phx-click="toggle_active">Toggle</button>
    </div>
    """
  end
end

defmodule Lavash.Test.Magic.GuardedActionsLive do
  @moduledoc """
  Test fixture: LiveView with guarded actions (when clause).
  """
  use Lavash.LiveView

  state :enabled, :boolean, from: :ephemeral, default: false
  state :count, :integer, from: :ephemeral, default: 0
  state :effect_log, :string, from: :ephemeral, default: ""

  actions do
    action :enable do
      set :enabled, true
    end

    action :disable do
      set :enabled, false
    end

    # Third argument is the guard list
    action :guarded_increment, [], [:enabled] do
      set :count, rx(@count + 1)
    end

    action :increment_with_effect do
      set :count, rx(@count + 1)

      effect fn state ->
        send(self(), {:effect_ran, state.count})
      end
    end
  end

  def render(assigns) do
    ~H"""
    <div>
      <span id="enabled">{@enabled}</span>
      <span id="count">{@count}</span>
      <span id="effect-log">{@effect_log}</span>
      <button id="enable" phx-click="enable">Enable</button>
      <button id="disable" phx-click="disable">Disable</button>
      <button id="guarded-inc" phx-click="guarded_increment">Guarded Inc</button>
      <button id="inc-with-effect" phx-click="increment_with_effect">Inc with Effect</button>
    </div>
    """
  end
end

defmodule Lavash.Test.Magic.CustomMountLive do
  @moduledoc """
  Test fixture: LiveView with a user-defined `mount/3` that chains into
  `Lavash.LiveView.Runtime.mount/4` and adds its own assign.

  Exercises Issue #1 (mount/3 must be overridable so users can do their own
  per-route setup without losing the reactive graph init).
  """
  use Lavash.LiveView

  state :count, :integer, from: :url, default: 0

  actions do
    action :increment do
      set :count, rx(@count + 1)
    end
  end

  @impl Phoenix.LiveView
  def mount(params, session, socket) do
    {:ok, socket} = Lavash.LiveView.Runtime.mount(__MODULE__, params, session, socket)
    {:ok, Phoenix.Component.assign(socket, :greeting, "hello from custom mount")}
  end

  def render(assigns) do
    ~H"""
    <div>
      <span id="greeting">{@greeting}</span>
      <span id="count">{@count}</span>
      <button id="inc" phx-click="increment">+</button>
    </div>
    """
  end
end
