defmodule Lavash.Test.Magic.ArraysLive do
  @moduledoc """
  Fixture for array-state mutation tests. Renders the list as flat text and
  per-item presence flags rather than :for so the tests don't depend on the
  LavashOptimistic JS hook (which the test layout doesn't load).
  """
  use Lavash.LiveView

  state :items, {:array, :string}, from: :ephemeral, default: ["a", "b"]

  calculate :count, rx(length(@items)), optimistic: false
  calculate :joined, rx(Enum.join(@items, ",")), optimistic: false
  calculate :has_a, rx("a" in @items), optimistic: false
  calculate :has_b, rx("b" in @items), optimistic: false
  calculate :has_c, rx("c" in @items), optimistic: false
  calculate :has_d, rx("d" in @items), optimistic: false

  actions do
    action :add, [:name] do
      run fn assigns -> assign(assigns, :items, assigns.items ++ [assigns.name]) end
    end

    action :remove, [:name] do
      run fn assigns ->
        assign(assigns, :items, Enum.reject(assigns.items, &(&1 == assigns.name)))
      end
    end

    action :clear do
      run fn assigns -> assign(assigns, :items, []) end
    end
  end

  def render(assigns) do
    ~H"""
    <div>
      <span id="count">{@count}</span>
      <span id="joined">{@joined}</span>
      <span :if={@has_a} id="item-a">a</span>
      <span :if={@has_b} id="item-b">b</span>
      <span :if={@has_c} id="item-c">c</span>
      <span :if={@has_d} id="item-d">d</span>

      <button id="add-c" phx-click="add" phx-value-name="c">Add c</button>
      <button id="add-d" phx-click="add" phx-value-name="d">Add d</button>
      <button id="remove-a" phx-click="remove" phx-value-name="a">Remove a</button>
      <button id="remove-b" phx-click="remove" phx-value-name="b">Remove b</button>
      <button id="clear" phx-click="clear">Clear</button>
    </div>
    """
  end
end
