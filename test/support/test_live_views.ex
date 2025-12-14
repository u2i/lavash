defmodule Lavash.TestCounterLive do
  @moduledoc """
  Test fixture: Simple counter with URL state.
  """
  use Lavash.LiveView

  state do
    url do
      field :count, :integer, default: 0
    end

    ephemeral do
      field :multiplier, :integer, default: 2
    end
  end

  derived do
    field :doubled, depends_on: [:count, :multiplier], compute: fn %{count: c, multiplier: m} ->
      c * m
    end
  end

  assigns do
    assign :count
    assign :multiplier
    assign :doubled
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

  state do
    url do
      field :count, :integer, default: 1
    end
  end

  derived do
    field :doubled, depends_on: [:count], compute: fn %{count: c} ->
      c * 2
    end

    field :quadrupled, depends_on: [:doubled], compute: fn %{doubled: d} ->
      d * 2
    end

    field :octupled, depends_on: [:quadrupled], compute: fn %{quadrupled: q} ->
      q * 2
    end
  end

  assigns do
    assign :count
    assign :doubled
    assign :quadrupled
    assign :octupled
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

  state do
    ephemeral do
      field :base, :integer, default: 1
    end
  end

  derived do
    field :doubled, depends_on: [:base], compute: fn %{base: b} ->
      b * 2
    end

    field :quadrupled, depends_on: [:doubled], compute: fn %{doubled: d} ->
      d * 2
    end

    field :octupled, depends_on: [:quadrupled], compute: fn %{quadrupled: q} ->
      q * 2
    end
  end

  assigns do
    assign :base
    assign :doubled
    assign :quadrupled
    assign :octupled
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

  state do
    url do
      field :count, :integer, default: 1
    end
  end

  derived do
    field :doubled, depends_on: [:count], async: true, compute: fn %{count: c} ->
      Process.sleep(50)
      c * 2
    end

    field :quadrupled, depends_on: [:doubled], compute: fn %{doubled: d} ->
      # d will be the raw value (unwrapped from {:ok, value})
      d * 2
    end
  end

  assigns do
    assign :count
    assign :doubled
    assign :quadrupled
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
          <% :loading -> %>loading
          <% {:ok, val} -> %>{val}
          <% val -> %>{val}
        <% end %>
      </span>
      <span id="quadrupled">
        <%= case @quadrupled do %>
          <% :loading -> %>loading
          <% {:ok, val} -> %>{val}
          <% val -> %>{val}
        <% end %>
      </span>
      <button id="inc" phx-click="increment">+</button>
    </div>
    """
  end
end

defmodule Lavash.TestTypedLive do
  @moduledoc """
  Test fixture: LiveView with various typed URL fields.
  """
  use Lavash.LiveView

  state do
    url do
      field :page, :integer, default: 1
      field :active, :boolean, default: false
      field :query, :string, default: ""
      field :tags, {:array, :string}, default: []
    end
  end

  assigns do
    assign :page
    assign :active
    assign :query
    assign :tags
  end

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
