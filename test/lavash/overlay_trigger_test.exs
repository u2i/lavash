defmodule Lavash.OverlayTriggerTest do
  @moduledoc """
  `template_trigger do ... end` on overlay components: the trigger
  renders outside the panel chrome, wrapped in a button carrying the
  dialog ARIA contract and the optimistic open wiring.
  """
  use Lavash.ConnCase, async: false

  import Phoenix.LiveViewTest

  defp visit_fixture(conn) do
    live(conn, "/magic/trigger-flyover?cart_id=cart-#{System.unique_integer([:positive])}")
  end

  test "trigger renders as an ARIA-wired button outside the chrome", %{conn: conn} do
    {:ok, view, _html} = visit_fixture(conn)

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
    {:ok, _view, html} = visit_fixture(conn)

    # The {@badge_count} in the trigger got a display span — proof the
    # trigger template went through the token pipeline like any other.
    assert html =~ ~s(data-lavash-display="badge_count")
  end

  test "host invoke drives the flyover's append server-side", %{conn: conn} do
    cart = "cart-#{System.unique_integer([:positive])}"
    {:ok, view, _html} = live(conn, "/magic/trigger-flyover?cart_id=#{cart}")

    view |> element("#add-remote") |> render_click()

    # invoke routes via send_update — the component updates in its own
    # cycle, so assert on a follow-up render.
    assert render(view) =~ ~s(data-lavash-display="badge_count">2</span>)

    [item] =
      Lavash.Test.Magic.ClientCart.Item
      |> Ash.Query.for_read(:for_cart, %{cart_id: cart})
      |> Ash.read!()

    assert item.name == "Widget"
    assert item.quantity == 2
  end

  test "modules without template_trigger render no trigger button", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/magic/modal-host")
    refute html =~ "data-lavash-overlay-trigger"
  end
end
