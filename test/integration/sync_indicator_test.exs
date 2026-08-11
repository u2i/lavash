defmodule Lavash.Integration.SyncIndicatorTest do
  @moduledoc """
  Sync-state DOM annotations end-to-end (issue #72, ClientCartLive
  fixture): while a prediction is unconfirmed the hook root carries
  `data-lavash-syncing` + `aria-busy`, and a provisional (appended)
  row carries `data-lavash-provisional` via its `data-lavash-id`;
  the confirming server patch clears all of it.

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

  test "append: syncing + provisional row annotations appear in-window, clear on confirm",
       %{session: session} do
    cart = unique_cart()

    session =
      session
      |> visit("/magic/client-cart?cart_id=#{cart}")
      |> WLV.set_latency(@latency_ms)

    try do
      session = click(session, css("#add-widget"), await: :defer)

      # In-window (bound far below the 2s round trip — this is the
      # client annotating its own prediction, not the server): the hook
      # root reports work in flight, with the a11y mirror, and the
      # predicted row itself is marked provisional.
      session = assert_has(session, css("[data-lavash-syncing]", wait: 600))
      session = assert_has(session, css("[data-lavash-syncing][aria-busy='true']", wait: 600))

      session =
        assert_has(session, css("[data-lavash-provisional] .row-name", text: "Widget", wait: 600))

      # The same event's re-read replaces the seeded row — every
      # annotation derives from SyncedVar state, so all of it clears.
      session = WLV.await_patch(session)
      session = refute_has(session, css("[data-lavash-provisional]", wait: 2_000))
      session = refute_has(session, css("[data-lavash-syncing]", wait: 2_000))
      refute_has(session, css("[aria-busy='true']", wait: 500))
    after
      _ = WLV.clear_latency(session)
    end
  end

  test "mutate: pending prediction sets syncing, confirm clears it", %{session: session} do
    cart = unique_cart()
    item = create_item!(cart, "Beans", 2, "9.50")

    session =
      session
      |> visit("/magic/client-cart?cart_id=#{cart}")
      |> WLV.set_latency(@latency_ms)

    try do
      session = assert_has(session, css("#item-#{item.id} .qty", text: "2"))

      session = click(session, css("#item-#{item.id} button", text: "+"), await: :defer)

      session = assert_has(session, css("[data-lavash-syncing]", wait: 600))
      # A mutate is a pending optimistic set, not a provisional seed —
      # no row-level provisional marking.
      session = refute_has(session, css("[data-lavash-provisional]", wait: 0))

      session = WLV.await_patch(session)
      session = assert_has(session, css("#item-#{item.id} .qty", text: "3"))
      refute_has(session, css("[data-lavash-syncing]", wait: 2_000))
    after
      _ = WLV.clear_latency(session)
    end
  end

  test "no annotations at rest", %{session: session} do
    cart = unique_cart()
    create_item!(cart, "Beans", 1, "4.00")

    session = visit(session, "/magic/client-cart?cart_id=#{cart}")

    session = assert_has(session, css(".row-name", text: "Beans"))
    session = refute_has(session, css("[data-lavash-syncing]", wait: 0))
    refute_has(session, css("[data-lavash-provisional]", wait: 0))
  end
end
