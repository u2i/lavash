defmodule Lavash.Parity.FunctionalComponentsTest do
  @moduledoc """
  Parity suite: cross-module function components.

  Vanilla side imports `Lavash.Parity.SharedComponents` (a
  plain Phoenix.Component module with positional `attr`/`slot`
  declarations).

  Lavash side imports `Lavash.Parity.SharedComponentsLavash`
  (the same components defined via the block-structured
  `components do component :foo do ... end end` DSL).

  Both compile to equivalent Phoenix function components.
  Identical rendered output verifies the lavash block DSL
  produces a Phoenix-compatible result.
  """
  use Lavash.ConnCase, async: true

  @paths [
    {"vanilla", "/parity/vanilla/functional_components"},
    {"lavash", "/parity/lavash/functional_components"}
  ]

  for {label, path} <- @paths do
    @path path

    describe "button component (#{label})" do
      test "renders with default variant", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path)
        assert has_element?(view, "button#b1.btn.btn-primary", "Click me")
      end

      test "applies variant + class + :rest global passthrough", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path)
        # variant=danger → btn-danger, class="big" applied, disabled passed through
        assert has_element?(view, "button#b2.btn.btn-danger.big[disabled]", "Delete")
      end
    end

    describe "badge component (#{label})" do
      test "renders label + count when count > 0", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path)
        assert has_element?(view, ".badge.badge-info .badge-label", "messages")
        assert has_element?(view, ".badge.badge-info .badge-count", "3")
      end

      test "omits count span when count == 0", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path)

        # The "empty" badge should not include a count span. We can't
        # easily express "the count==0 badge has no .badge-count" with
        # has_element?, so we render and check the HTML directly.
        # Two badges total; one (count=3) HAS .badge-count, the other
        # (count=0) doesn't. So overall we expect exactly one
        # .badge-count in the rendered page.
        html = render(view)
        count_count = html |> String.split("badge-count") |> length() |> Kernel.-(1)
        assert count_count == 1, "expected exactly 1 .badge-count, got #{count_count}"
      end
    end

    describe "recursive tree_node (#{label})" do
      test "renders root and direct children", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path)
        assert has_element?(view, "#tree .tree-node .node-label", "root")
        assert has_element?(view, "#tree .children .tree-node .node-label", "a")
        assert has_element?(view, "#tree .children .tree-node .node-label", "b")
      end

      test "recurses into nested children", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path)
        # b1 is two levels deep inside the tree
        assert has_element?(
                 view,
                 "#tree .tree-node .children .tree-node .children .tree-node",
                 "b1"
               )
      end
    end
  end
end
