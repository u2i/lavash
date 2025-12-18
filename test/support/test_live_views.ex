defmodule Lavash.TestCounterLive do
  @moduledoc """
  Test fixture: Simple counter with URL state.
  """
  use Lavash.LiveView

  state :count, :integer, from: :url, default: 0
  state :multiplier, :integer, from: :ephemeral, default: 2

  derive :doubled do
    argument :count, state(:count)
    argument :multiplier, state(:multiplier)
    run fn %{count: c, multiplier: m}, _ -> c * m end
  end

  actions do
    action :increment do
      update :count, &(&1 + 1)
    end

    action :decrement do
      update :count, &(&1 - 1)
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

defmodule Lavash.TestChainedDerivedLive do
  @moduledoc """
  Test fixture: Derived fields that depend on other derived fields.
  count → doubled → quadrupled
  """
  use Lavash.LiveView

  state :count, :integer, from: :url, default: 1

  derive :doubled do
    argument :count, state(:count)
    run fn %{count: c}, _ -> c * 2 end
  end

  derive :quadrupled do
    argument :doubled, result(:doubled)
    run fn %{doubled: d}, _ -> d * 2 end
  end

  derive :octupled do
    argument :quadrupled, result(:quadrupled)
    run fn %{quadrupled: q}, _ -> q * 2 end
  end

  actions do
    action :increment do
      update :count, &(&1 + 1)
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

defmodule Lavash.TestChainedEphemeralLive do
  @moduledoc """
  Test fixture: Chained derived fields from ephemeral state.
  This tests recompute_dirty (not recompute_all) since ephemeral
  state changes don't trigger handle_params.
  """
  use Lavash.LiveView

  state :base, :integer, from: :ephemeral, default: 1

  derive :doubled do
    argument :base, state(:base)
    run fn %{base: b}, _ -> b * 2 end
  end

  derive :quadrupled do
    argument :doubled, result(:doubled)
    run fn %{doubled: d}, _ -> d * 2 end
  end

  derive :octupled do
    argument :quadrupled, result(:quadrupled)
    run fn %{quadrupled: q}, _ -> q * 2 end
  end

  actions do
    action :increment do
      update :base, &(&1 + 1)
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

defmodule Lavash.TestAsyncChainLive do
  @moduledoc """
  Test fixture: Async derived fields in a chain.
  count → async_doubled → sync_quadrupled
  """
  use Lavash.LiveView

  state :count, :integer, from: :url, default: 1

  derive :doubled do
    async true
    argument :count, state(:count)

    run fn %{count: c}, _ ->
      Process.sleep(50)
      c * 2
    end
  end

  derive :quadrupled do
    argument :doubled, result(:doubled)

    run fn %{doubled: d}, _ ->
      # d will be the raw value (unwrapped from {:ok, value})
      d * 2
    end
  end

  actions do
    action :increment do
      update :count, &(&1 + 1)
    end
  end

  def render(assigns) do
    ~H"""
    <div>
      <span id="count">{@count}</span>
      <span id="doubled">
        <%= case @doubled do %>
          <% %Phoenix.LiveView.AsyncResult{loading: true} -> %>loading
          <% %Phoenix.LiveView.AsyncResult{ok?: true, result: val} -> %>{val}
          <% val -> %>{val}
        <% end %>
      </span>
      <span id="quadrupled">
        <%= case @quadrupled do %>
          <% %Phoenix.LiveView.AsyncResult{loading: true} -> %>loading
          <% %Phoenix.LiveView.AsyncResult{ok?: true, result: val} -> %>{val}
          <% val -> %>{val}
        <% end %>
      </span>
      <button id="inc" phx-click="increment">+</button>
    </div>
    """
  end
end

defmodule Lavash.TestPathParamLive do
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
      update :product_id, &(&1 + 1)
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

defmodule Lavash.TestTypedLive do
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
      update :active, &(!&1)
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
