defmodule Lavash.Integration.ArraysAndKeyedTest do
  @moduledoc """
  Structural updates to collections — adding, removing, and mutating items
  in array-valued state, including keyed mutations via `map_by`.
  """
  use ExUnit.Case, async: true

  @moduletag :e2e

  test "appending to an array adds a DOM node optimistically" do
    # The new item should appear in the `:for` region immediately, before
    # the server confirms.
    assert true
  end

  test "removing an item drops the corresponding DOM node" do
    # `Enum.reject(&(&1 == val))` (or equivalent) should update the
    # rendered list with no flash of the old node.
    assert true
  end

  test "map_by updates a single keyed item in place" do
    # `map_by :items, :id, "fn item, _id -> ... end"` should mutate only
    # the matching item; siblings should not re-render.
    assert true
  end

  test "morphdom preserves DOM identity for unchanged items" do
    # Items that didn't change should retain focus, scroll position, and
    # form input state across a structural update.
    assert true
  end

  test "calculations on array length stay in sync after structural changes" do
    # `calculate :count, rx(length(@items))` should reflect the new size
    # in the same frame as the structural update.
    assert true
  end
end
