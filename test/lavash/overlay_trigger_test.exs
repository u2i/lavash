defmodule Lavash.OverlayTriggerTest do
  @moduledoc """
  `template_trigger do ... end` on overlay components: the trigger
  renders outside the panel chrome, wrapped in a button carrying the
  dialog ARIA contract and the optimistic open wiring.
  """
  use Lavash.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "trigger renders as an ARIA-wired button outside the chrome", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/magic/trigger-flyover")

    trigger = view |> element(~s([data-lavash-overlay-trigger="trig-fly-flyover"])) |> render()

    assert trigger =~ ~s(aria-haspopup="dialog")
    assert trigger =~ ~s(aria-expanded="false")
    assert trigger =~ ~s(aria-controls="trig-fly-flyover-panel_content")
    assert trigger =~ "Cart ("

    # The trigger content is NOT inside the panel.
    panel = view |> element("#trig-fly-flyover-panel_content") |> render()
    refute panel =~ "trigger-content"
  end

  test "trigger count renders through the optimistic pipeline", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/magic/trigger-flyover")

    # The {@count} in the trigger got a display span — proof the trigger
    # template went through the token pipeline like any other template.
    assert html =~ ~s(data-lavash-display="count")
  end

  test "modules without template_trigger render no trigger button", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/magic/modal-host")
    refute html =~ "data-lavash-overlay-trigger"
  end
end
