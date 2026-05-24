defmodule Lavash.Integration.BindingsTest do
  @moduledoc """
  Component bindings — a child bound via `bind={[child_field: parent_field]}`
  reads and writes the parent's field, with updates propagating through
  arbitrarily nested component hierarchies.

  Fixtures live in test/support/test_binding_fixtures.ex.
  """
  use Lavash.IntegrationCase, async: false

  test "child component mutation updates the parent's DOM", %{session: session} do
    session
    |> visit("/bindings-direct")
    |> assert_has(css("#parent-count", text: "0"))
    |> assert_has(css("#child-direct-n", text: "0"))
    |> click(css("#child-direct-bump"))
    |> assert_has(css("#parent-count", text: "1"))
    |> assert_has(css("#child-direct-n", text: "1"))
  end

  test "multiple mutations keep parent and child in sync", %{session: session} do
    session
    |> visit("/bindings-direct")
    |> click(css("#child-direct-bump"))
    |> click(css("#child-direct-bump"))
    |> click(css("#child-direct-bump"))
    |> assert_has(css("#parent-count", text: "3"))
    |> assert_has(css("#child-direct-n", text: "3"))
  end

  test "binding chains work across two levels of nesting", %{session: session} do
    # LiveView (root_count) -> middle (m) -> grandchild (n). Writing the
    # grandchild's bump should propagate two hops up to root_count.
    session
    |> visit("/bindings-nested")
    |> assert_has(css("#root-count", text: "0"))
    |> assert_has(css("#middle-middle-m", text: "0"))
    |> assert_has(css("#child-middle-grandchild-n", text: "0"))
    |> click(css("#child-middle-grandchild-bump"))
    |> assert_has(css("#root-count", text: "1"))
    |> assert_has(css("#middle-middle-m", text: "1"))
    |> assert_has(css("#child-middle-grandchild-n", text: "1"))
  end

  test "sibling components bound to the same field sync via the parent", %{session: session} do
    # Two children both bound to :shared. Either child's bump should:
    #   1. Update the parent's :shared via binding propagation
    #   2. Re-render both children with the new shared value
    # so subsequent bumps from either child see the up-to-date value.
    session
    |> visit("/bindings-siblings")
    |> assert_has(css("#shared", text: "0"))
    |> assert_has(css("#child-a-n", text: "0"))
    |> assert_has(css("#child-b-n", text: "0"))
    |> click(css("#child-a-bump"))
    |> assert_has(css("#shared", text: "1"))
    |> assert_has(css("#child-a-n", text: "1"))
    |> assert_has(css("#child-b-n", text: "1"))
    |> click(css("#child-b-bump"))
    |> assert_has(css("#shared", text: "2"))
    |> assert_has(css("#child-a-n", text: "2"))
    |> assert_has(css("#child-b-n", text: "2"))
  end

  test "binding chain survives parent re-render", %{session: session} do
    # After a parent state mutation, the binding map should still be in
    # place when the next child action fires.
    session
    |> visit("/bindings-direct")
    |> click(css("#child-direct-bump"))
    |> click(css("#child-direct-bump"))
    |> assert_has(css("#parent-count", text: "2"))
    |> assert_has(css("#child-direct-n", text: "2"))
  end
end
