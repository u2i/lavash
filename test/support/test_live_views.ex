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
