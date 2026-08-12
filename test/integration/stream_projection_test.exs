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

  # The Entry table is shared (private? false) and Ash's ETS data layer
  # filters IN MEMORY after casting every record — so the 10k-row test
  # would make every later read in the file take seconds (the seed-order
  # "flaky" failures were reads outlasting assertion windows). Drop the
  # table after each test.
  setup do
    on_exit(fn -> Ash.DataLayer.Ets.stop(Entry) end)
    :ok
  end

  defp seed!(list_id, n) do
    Enum.each(1..n, fn i -> seed_one!(list_id, "row #{i}") end)
  end

  defp seed_one!(list_id, body) do
    Entry
    |> Ash.Changeset.for_create(:create, %{list_id: list_id, body: body})
    |> Ash.create!()
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
      _session = refute_has(session, css("[data-lavash-syncing]", wait: 2_000))

      # Server truth: the record exists under the client-minted id.
      "items-" <> uuid = predicted_id
      assert {:ok, %Entry{body: "fresh"}} = Ash.get(Entry, uuid)
    after
      _ = WLV.clear_latency(session)
    end
  end

  # ── Phase 2: keyed row ops ─────────────────────────────────────

  test "mutate predicts a row re-render from its data-lavash-row; confirm morphs in place",
       %{session: session} do
    list = unique_list()
    [entry | _] = for i <- 1..2, do: seed_one!(list, "row #{i}")

    session =
      session
      |> visit("/magic/stream-list?list_id=#{list}")
      |> WLV.set_latency(@latency_ms)

    try do
      session = assert_has(session, css("#items-#{entry.id} .count", text: "1"))

      session = click(session, css("#items-#{entry.id} .inc"), await: :defer)

      # In-window: the SAME row re-rendered with the bumped count,
      # marked provisional.
      session =
        assert_has(
          session,
          css("#items-#{entry.id}[data-lavash-provisional] .count", text: "2", wait: 600)
        )

      session = assert_has(session, css("[data-lavash-syncing]", wait: 600))

      session = WLV.await_patch(session)
      session = assert_has(session, css("#items-#{entry.id} .count", text: "2", wait: 2_000))
      session = refute_has(session, css("[data-lavash-provisional]", wait: 2_000))
      refute_has(session, css("[data-lavash-syncing]", wait: 2_000))
    after
      _ = WLV.clear_latency(session)
    end
  end

  test "remove predicts the row dropping; the delete resolves on the confirming patch",
       %{session: session} do
    list = unique_list()
    [entry, keeper] = for i <- 1..2, do: seed_one!(list, "row #{i}")

    session =
      session
      |> visit("/magic/stream-list?list_id=#{list}")
      |> WLV.set_latency(@latency_ms)

    try do
      session = assert_has(session, css("#items-#{entry.id}"))

      session = click(session, css("#items-#{entry.id} .del"), await: :defer)

      # In-window: the row is gone (bound below the round trip) and
      # the hook reports the unconfirmed delete.
      session = refute_has(session, css("#items-#{entry.id}", wait: 600))
      session = assert_has(session, css("[data-lavash-syncing]", wait: 600))

      session = WLV.await_patch(session)
      session = refute_has(session, css("#items-#{entry.id}", wait: 1_000))
      session = assert_has(session, css("#items-#{keeper.id}"))
      _session = refute_has(session, css("[data-lavash-syncing]", wait: 2_000))

      assert {:ok, nil} = Ash.get(Entry, entry.id, error?: false)
    after
      _ = WLV.clear_latency(session)
    end
  end

  test "upsert conflict re-renders the matched row; miss inserts a new one",
       %{session: session} do
    list = unique_list()
    [entry | _] = for i <- 1..2, do: seed_one!(list, "row #{i}")

    session =
      session
      |> visit("/magic/stream-list?list_id=#{list}")
      |> WLV.set_latency(@latency_ms)

    try do
      # Conflict branch: "row 1" exists — its count ticks on that row.
      session = click(session, css("#upsert"), await: :defer)

      session =
        assert_has(
          session,
          css("#items-#{entry.id}[data-lavash-provisional] .count", text: "2", wait: 600)
        )

      session = WLV.await_patch(session)
      session = assert_has(session, css("#items-#{entry.id} .count", text: "2", wait: 2_000))
      session = refute_has(session, css("[data-lavash-provisional]", wait: 2_000))

      # Insert branch: "brand new" doesn't exist — a provisional row
      # appears and confirms under the same client-minted id.
      session = click(session, css("#upsert-new"), await: :defer)

      session =
        assert_has(
          session,
          css("#items [data-lavash-provisional] .body", text: "brand new", wait: 600)
        )

      new_id = eval(session, ~s|document.querySelector("#items [data-lavash-provisional]").id|)

      session = WLV.await_patch(session)
      session = assert_has(session, css("##{new_id} .body", text: "brand new", wait: 2_000))
      refute_has(session, css("[data-lavash-provisional]", wait: 2_000))
    after
      _ = WLV.clear_latency(session)
    end
  end

  # ── Phase 3: targeted PubSub row invalidation ──────────────────

  test "a cross-process write arrives as a targeted row op", %{session: session} do
    list = unique_list()
    seed_one!(list, "row 1")

    session = visit(session, "/magic/stream-list?list_id=#{list}")

    # PubSub delivery requires the CONNECTED mount's subscription —
    # asserting against static HTML isn't enough (a broadcast fired
    # into the join gap is silently lost; that was this test's flake).
    session = assert_has(session, css("[data-phx-main].phx-connected", wait: 5_000))
    session = assert_has(session, css("#items .entry .body", text: "row 1"))

    # Another process writes and broadcasts record-level detail — the
    # view requeries just that record through its read (the list filter
    # applies) and stream-inserts it.
    entry = seed_one!(list, "from elsewhere")
    Lavash.PubSub.broadcast_record(Entry, {:written, entry.id})

    session = assert_has(session, css("#items-#{entry.id} .body", text: "from elsewhere"))

    # A record that does NOT match the view's filter must not appear.
    other = seed_one!("some-other-list", "not mine")
    Lavash.PubSub.broadcast_record(Entry, {:written, other.id})

    refute_has(session, css("#items-#{other.id}", wait: 500))

    # Cross-process ROW REMOVAL ({:deleted, id} → reset re-stream) is
    # covered at the LiveViewTest level (stream_invalidation_test) —
    # the server-side semantics are deterministic there. At the
    # browser layer the removal intermittently fails to apply in this
    # harness (both lightpanda and Chrome; a captured wire trace shows
    # the diff arriving and the node surviving) — tracked as a
    # follow-up investigation into LiveView client stream-removal
    # application, see the issue referenced in
    # docs/STREAM_PROJECTIONS.md.
  end

  # ── Phase 4: ordering + limit ──────────────────────────────────

  test "at 0 prepends: prediction and confirmation both land at the top",
       %{session: session} do
    list = unique_list()
    for i <- 1..3, do: seed_one!(list, "row #{i}")

    session =
      session
      |> visit("/magic/stream-prepend?list_id=#{list}")
      |> WLV.set_latency(@latency_ms)

    try do
      session = assert_has(session, css("#items .entry .body", text: "row 3"))

      session = click(session, css("#add"), await: :defer)

      # In-window: the predicted row is the FIRST child.
      session =
        assert_has(
          session,
          css("#items .entry:first-child[data-lavash-provisional] .body",
            text: "newest",
            wait: 600
          )
        )

      # Confirmed: still first, no longer provisional.
      session = WLV.await_patch(session)

      session =
        assert_has(
          session,
          css("#items .entry:first-child .body", text: "newest", wait: 2_000)
        )

      session = refute_has(session, css("[data-lavash-provisional]", wait: 2_000))

      # limit 5: the container never grows past the cap after confirms.
      assert eval(session, ~s|document.querySelectorAll("#items .entry").length|) <= 5
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
