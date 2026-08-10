defmodule Lavash.Integration.ClientStateTest do
  @moduledoc """
  client_state projections end-to-end (ClientCartLive fixture): an
  Ash resource list mapped onto the client, `map_by` predictions
  applied instantly, confirmed by the same event's post-write
  re-read, and propagated to other sessions via PubSub.

  ## Why async: false

  Uses the LiveView latency simulator (sessionStorage on the shared
  browser session); concurrent tests would cross-pollute it.
  """
  use Lavash.IntegrationCase, async: false

  alias Lavash.Test.Magic.ClientCart.Item
  alias Wallabidi.LiveView, as: WLV

  @latency_ms 1_000

  defp create_item!(cart_id, name, quantity, price) do
    Item
    |> Ash.Changeset.for_create(:create, %{
      cart_id: cart_id,
      name: name,
      quantity: quantity,
      unit_price: Decimal.new(price)
    })
    |> Ash.create!()
  end

  defp unique_cart, do: "cart-#{System.unique_integer([:positive])}"

  defp qty(item_id, text) do
    css("#item-#{item_id} .qty", text: text)
  end

  test "map_by predicts instantly; the server write confirms it", %{session: session} do
    cart = unique_cart()
    item = create_item!(cart, "Beans", 2, "9.50")

    session =
      session
      |> visit("/magic/client-cart?cart_id=#{cart}")
      |> WLV.set_latency(@latency_ms)

    session = assert_has(session, qty(item.id, "2"))

    try do
      # Click without waiting for the server ack.
      session = click(session, css("#item-#{item.id} button", text: "+"), await: :defer)

      # Deep inside the lag window: the row qty and the calc over the
      # projection both updated client-side already.
      session = assert_has(session, qty(item.id, "3"))
      session = assert_has(session, css("#count", text: "3"))

      # After the round-trip the prediction stands (confirmed, not
      # reverted) and the write persisted.
      session = WLV.await_patch(session)
      session = assert_has(session, qty(item.id, "3"))
      assert Ash.get!(Item, item.id).quantity == 3

      # Reload: the projection re-seeds from the database.
      session = visit(session, "/magic/client-cart?cart_id=#{cart}")
      assert_has(session, qty(item.id, "3"))
    after
      _ = WLV.clear_latency(session)
    end
  end

  test "remove predicts instantly and persists", %{session: session} do
    cart = unique_cart()
    item = create_item!(cart, "Beans", 1, "4.00")
    keeper = create_item!(cart, "Filter", 1, "3.00")

    session =
      session
      |> visit("/magic/client-cart?cart_id=#{cart}")
      |> WLV.set_latency(@latency_ms)

    session = assert_has(session, qty(item.id, "1"))

    try do
      session = click(session, css("#item-#{item.id} button", text: "x"), await: :defer)

      # Gone client-side within the lag window; the other row stays.
      refute_has(session, css("#item-#{item.id}", wait: 0))
      session = assert_has(session, qty(keeper.id, "1"))

      session = WLV.await_patch(session)
      refute_has(session, css("#item-#{item.id}", wait: 0))
      assert {:error, _} = Ash.get(Item, item.id)
    after
      _ = WLV.clear_latency(session)
    end
  end

  test "another session on the same cart updates via PubSub", %{session: session_a} do
    cart = unique_cart()
    item = create_item!(cart, "Beans", 2, "9.50")

    {:ok, session_b} = Wallabidi.start_session(metadata: %{}, max_wait_time: 5_000)

    try do
      session_a = visit(session_a, "/magic/client-cart?cart_id=#{cart}")
      session_b = visit(session_b, "/magic/client-cart?cart_id=#{cart}")

      session_b = assert_has(session_b, qty(item.id, "2"))

      # Mutate in session A…
      session_a = click(session_a, css("#item-#{item.id} button", text: "+"))
      assert_has(session_a, qty(item.id, "3"))

      # …and session B converges through broadcast → invalidate →
      # re-read → push (its SyncedVar has no pending prediction, so
      # the server value is accepted directly).
      assert_has(session_b, qty(item.id, "3"))
      assert_has(session_b, css("#count", text: "3"))
    after
      Wallabidi.end_session(session_b)
    end
  end
end
