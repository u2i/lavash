defmodule Lavash.Parity.RenderSlotsTest do
  @moduledoc """
  Parity suite: function-component slots inside templates.

  Both sides use Phoenix.Component's `attr` + `slot` +
  `render_slot/1` machinery. Lavash imports Phoenix.Component
  by default, so the same code runs in both. The test verifies
  that wrapping `~H` in a `template do ... end` block doesn't
  break slot rendering.
  """
  use Lavash.ConnCase, async: true

  @paths [
    {"vanilla", "/parity/vanilla/render_slots"},
    {"lavash", "/parity/lavash/render_slots"}
  ]

  for {label, path} <- @paths do
    @path path

    describe "function component slots (#{label})" do
      test "required slot renders into its slot position", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path)
        # Lavash auto-wraps bare `{@name}` in <span data-lavash-display>,
        # so the literal "Welcome, world" only matches on vanilla.
        # Assert on the card-header element instead.
        assert has_element?(view, ".card-header", "Welcome,")
        assert has_element?(view, ".card-header", "world")
      end

      test "implicit inner_block renders body content", %{conn: conn} do
        {:ok, _view, html} = live(conn, @path)
        assert html =~ "Body text inside the implicit inner_block"
      end

      test "optional slot renders when provided", %{conn: conn} do
        {:ok, _view, html} = live(conn, @path)
        assert html =~ "cheers"
      end

      test ":let-bound slot variable is in scope inside the slot body", %{conn: conn} do
        {:ok, _view, html} = live(conn, @path)
        assert html =~ "alpha"
        assert html =~ "beta"
      end

      test "structural classes from the component are rendered", %{conn: conn} do
        {:ok, _view, html} = live(conn, @path)
        assert html =~ ~s|class="card"|
        assert html =~ ~s|class="card-header"|
        assert html =~ ~s|class="card-body"|
        assert html =~ ~s|class="card-footer"|
      end
    end
  end
end
