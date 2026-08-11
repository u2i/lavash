defmodule Lavash.Integration.OverlayTriggerTest do
  @moduledoc """
  `template_trigger` + `invoke`'s client half, end-to-end: clicking
  the trigger opens the overlay optimistically; a HOST action that
  invokes the flyover's `append` bumps the projection-backed badge in
  the same tick — before the server reply.

  ## Why async: false

  Latency simulator + global focus/overlay state.
  """
  use Lavash.IntegrationCase, async: false

  alias Lavash.Test.Magic.ClientCart.Item
  alias Wallabidi.LiveView, as: WLV

  @latency_ms 1_000
  @trigger ~s([data-lavash-overlay-trigger="trig-fly-flyover"])

  defp create_item!(cart_id, name, quantity) do
    Item
    |> Ash.Changeset.for_create(:create, %{
      cart_id: cart_id,
      name: name,
      quantity: quantity,
      unit_price: Decimal.new("1.00")
    })
    |> Ash.create!()
  end

  defp unique_cart, do: "cart-#{System.unique_integer([:positive])}"

  test "trigger click opens the flyover optimistically", %{session: session} do
    cart = unique_cart()

    session =
      session
      |> visit("/magic/trigger-flyover?cart_id=#{cart}")
      |> WLV.set_latency(@latency_ms)

    session = assert_has(session, css(~s(#{@trigger}[aria-expanded="false"])))

    try do
      session = click(session, css(@trigger), await: :defer)

      # Deep inside the lag window: phase already left idle client-side
      # and the trigger reports expanded.
      session =
        assert_has(
          session,
          css(
            ~s(#lavash-trig-fly[data-flyover-phase="entering"], #lavash-trig-fly[data-flyover-phase="visible"])
          )
        )

      session = assert_has(session, css(~s(#{@trigger}[aria-expanded="true"])))

      # Settles open after the round trip.
      session = WLV.await_patch(session)
      session = assert_has(session, css(~s(#lavash-trig-fly[data-flyover-phase="visible"])))

      # Escape closes (a11y stack) and the trigger reports collapsed again.
      session = send_keys(session, [:escape])
      session = assert_has(session, css(~s(#lavash-trig-fly[data-flyover-phase="idle"])))
      assert_has(session, css(~s(#{@trigger}[aria-expanded="false"])))
    after
      _ = WLV.clear_latency(session)
    end
  end

  test "host invoke bumps the projected badge in the same tick", %{session: session} do
    cart = unique_cart()
    create_item!(cart, "Seeded", 3)

    session =
      session
      |> visit("/magic/trigger-flyover?cart_id=#{cart}")
      |> WLV.set_latency(@latency_ms)

    session = assert_has(session, css("#badge-count", text: "3"))

    try do
      session = click(session, css("#add-remote"), await: :defer)

      # Deep inside the lag window: invoke's client half ran the
      # flyover's append prediction — badge 3 -> 5 (qty 2) before any
      # server response exists.
      session = assert_has(session, css("#badge-count", text: "5"))

      # After the round trip the count stands (the re-read replaced the
      # provisional row with the real one) and the write persisted with
      # dedup semantics available.
      session = WLV.await_patch(session)
      session = assert_has(session, css("#badge-count", text: "5"))

      items = Item |> Ash.Query.for_read(:for_cart, %{cart_id: cart}) |> Ash.read!()
      assert Enum.find(items, &(&1.name == "Widget")).quantity == 2
    after
      _ = WLV.clear_latency(session)
    end
  end
end
