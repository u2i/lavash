defmodule Lavash.Integration.StreamProjectionTest do
  @moduledoc """
  Stream-backed projections end-to-end (issue #71, StreamListLive
  fixture): the rows live in a LiveView stream — NOT in assigns or
  `data-lavash-state` — and `append` predicts a per-row DOM insert
  under the client-minted id, confirmed by the same event's
  `stream_insert` morphing that exact node (the provisional marker is
  stripped, never a remove/re-add).

  ## Why async: false

  Uses the LiveView latency simulator (sessionStorage on the shared
  browser session); concurrent tests would cross-pollute it.
  """
  use Lavash.IntegrationCase, async: false

  alias Lavash.Test.Magic.StreamList.Entry
  alias Wallabidi.LiveView, as: WLV

  @latency_ms 1_000

  defp seed!(list_id, n) do
    Enum.each(1..n, fn i ->
      Entry
      |> Ash.Changeset.for_create(:create, %{list_id: list_id, body: "row #{i}"})
      |> Ash.create!()
    end)
  end

  defp unique_list, do: "list-#{System.unique_integer([:positive])}"

  defp eval(session, script) do
    execute_script(session, "return #{script}", fn value -> send(self(), {:eval, value}) end)

    receive do
      {:eval, value} -> value
    after
      5_000 -> :timeout
    end
  end

  test "rows are streamed, not shipped in client state", %{session: session} do
    list = unique_list()
    seed!(list, 5)

    session = visit(session, "/magic/stream-list?list_id=#{list}")
    session = assert_has(session, css("#items .entry .body", text: "row 5"))

    # The whole point: no list copy on the client. data-lavash-state
    # carries no :items, and the backing read's assign was released.
    assert eval(
             session,
             ~s|JSON.parse(document.querySelector("[data-lavash-state]").dataset.lavashState).items === undefined|
           ) == true
  end

  test "append predicts a provisional row; the stream_insert confirms the SAME node",
       %{session: session} do
    list = unique_list()
    seed!(list, 3)

    session =
      session
      |> visit("/magic/stream-list?list_id=#{list}")
      |> WLV.set_latency(@latency_ms)

    try do
      session = assert_has(session, css("#items .entry .body", text: "row 3"))

      session = click(session, css("#add"), await: :defer)

      # In-window (bound far below the 2s round trip): the predicted
      # row is in the stream container, provisional, and the hook
      # reports work in flight.
      session =
        assert_has(
          session,
          css("#items [data-lavash-provisional] .body", text: "fresh", wait: 600)
        )

      session = assert_has(session, css("[data-lavash-syncing]", wait: 600))

      predicted_id =
        eval(session, ~s|document.querySelector("#items [data-lavash-provisional]").id|)

      assert is_binary(predicted_id) and predicted_id != ""

      # After the round trip the confirming stream_insert lands on the
      # SAME dom id — client-minted identity — and the provisional
      # marker is gone.
      session = WLV.await_patch(session)
      session = assert_has(session, css("##{predicted_id} .body", text: "fresh", wait: 2_000))
      session = refute_has(session, css("[data-lavash-provisional]", wait: 2_000))
      session = refute_has(session, css("[data-lavash-syncing]", wait: 2_000))

      # Server truth: the record exists under the client-minted id.
      "items-" <> uuid = predicted_id
      assert {:ok, %Entry{body: "fresh"}} = Ash.get(Entry, uuid)
    after
      _ = WLV.clear_latency(session)
    end
  end

  @tag timeout: 120_000
  test "holds up at 10k rows", %{session: session} do
    list = unique_list()
    seed!(list, 10_000)

    session = visit(session, "/magic/stream-list?list_id=#{list}")
    session = assert_has(session, css("#items .entry .body", text: "row 10000", wait: 30_000))

    # Client state stays tiny regardless of list size.
    assert eval(
             session,
             ~s|JSON.parse(document.querySelector("[data-lavash-state]").dataset.lavashState).items === undefined|
           ) == true

    # Append still predicts instantly against a 10k-row container.
    session = WLV.set_latency(session, @latency_ms)

    try do
      session = click(session, css("#add"), await: :defer)

      session =
        assert_has(
          session,
          css("#items [data-lavash-provisional] .body", text: "fresh", wait: 600)
        )

      session = WLV.await_patch(session)
      refute_has(session, css("[data-lavash-provisional]", wait: 2_000))
    after
      _ = WLV.clear_latency(session)
    end
  end
end
