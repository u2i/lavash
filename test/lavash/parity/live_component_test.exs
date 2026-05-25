defmodule Lavash.Parity.LiveComponentTest do
  @moduledoc """
  Parity suite: LiveComponents.

  Vanilla side: `use Phoenix.LiveComponent` with `mount/1`,
  `update/2`, `handle_event/3`, `render/1`. Two instances
  hosted via `<.live_component>`.

  Lavash side: `use Lavash.Component` with `state`/`prop`/
  `actions`/`template`. Two instances hosted via
  `<.lavash_component>` (which adds binding-propagation on top
  of vanilla pass-through prop flow).

  Tests verify identical observable behaviour: independent
  per-instance state, parent-to-child prop flow on re-render,
  events routed via `phx-target={@myself}`.
  """
  use Lavash.ConnCase, async: true

  @paths [
    {"vanilla", "/parity/vanilla/live_component"},
    {"lavash", "/parity/lavash/live_component"}
  ]

  for {label, path} <- @paths do
    @path path

    describe "initial render (#{label})" do
      test "both instances render with their respective labels", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path)
        assert has_element?(view, "#comp-a .label", "A")
        assert has_element?(view, "#comp-b .label", "B")
      end

      test "both start with count 0", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path)
        assert has_element?(view, "#comp-a .count", "0")
        assert has_element?(view, "#comp-b .count", "0")
      end
    end

    describe "component-local events (#{label})" do
      test "clicking +1 on A doesn't affect B", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path)

        view |> element("#comp-a button", "+1") |> render_click()
        assert has_element?(view, "#comp-a .count", "1")
        assert has_element?(view, "#comp-b .count", "0")
      end

      test "clicking +1 multiple times accumulates per-instance", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path)

        view |> element("#comp-a button", "+1") |> render_click()
        view |> element("#comp-a button", "+1") |> render_click()
        view |> element("#comp-a button", "+1") |> render_click()
        view |> element("#comp-b button", "+1") |> render_click()

        assert has_element?(view, "#comp-a .count", "3")
        assert has_element?(view, "#comp-b .count", "1")
      end

      test "reset zeros only the targeted component", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path)

        view |> element("#comp-a button", "+1") |> render_click()
        view |> element("#comp-a button", "+1") |> render_click()
        view |> element("#comp-b button", "+1") |> render_click()

        view |> element("#comp-a button", "reset") |> render_click()

        assert has_element?(view, "#comp-a .count", "0")
        assert has_element?(view, "#comp-b .count", "1")
      end
    end

    describe "parent re-renders push props (#{label})" do
      test "parent toggling A's label updates the component", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path)

        assert has_element?(view, "#comp-a .label", "A")

        view |> element("#toggle-label-a") |> render_click()
        assert has_element?(view, "#comp-a .label", "A!")

        view |> element("#toggle-label-a") |> render_click()
        assert has_element?(view, "#comp-a .label", "A")
      end

      test "B's label is unaffected when A's toggles", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path)

        view |> element("#toggle-label-a") |> render_click()

        assert has_element?(view, "#comp-b .label", "B")
      end

      test "component-local state survives parent re-render", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path)

        view |> element("#comp-a button", "+1") |> render_click()
        view |> element("#comp-a button", "+1") |> render_click()
        assert has_element?(view, "#comp-a .count", "2")

        # Parent re-renders by changing A's label.
        view |> element("#toggle-label-a") |> render_click()

        # Component count survives.
        assert has_element?(view, "#comp-a .count", "2")
      end
    end
  end
end
