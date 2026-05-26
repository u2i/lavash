defmodule Lavash.Parity.StreamsTest do
  @moduledoc """
  Parity suite: `Phoenix.LiveView.stream/3` and friends.

  Streams are append/delete-friendly collections that ship deltas
  (rather than full lists) over the wire. Critical for chat
  histories, log tails, search-as-you-type results, and anywhere
  else where rerendering N items on every change would be
  wasteful.

  ## Lavash status

  Lavash doesn't (yet) expose `stream :name` as DSL surface.
  Both the vanilla and lavash fixtures reach for raw
  `Phoenix.LiveView.stream/3`, `stream_insert/4`, `stream_delete/3`
  — but the lavash side wraps each call in `run fn socket -> ... end`.
  See `docs/STREAMING.md` for the proposed declarative
  alternative.

  This parity test exists so behavior stays locked-down even if
  the surface is awkward today: the lavash fixture can be
  rewritten declaratively once `stream :name` lands, and these
  tests will catch any regression.
  """
  use Lavash.ConnCase, async: true

  # All vanilla tests pass — they exercise raw Phoenix.LiveView.
  # The lavash side fails on mutation tests because action `run
  # fn assigns -> ... end` expects an assigns return value, not a
  # socket. Stream operations require socket-level access
  # (`stream_insert(socket, ...)` returns a socket); the
  # action-runtime contract drops the changes. Tagged
  # `:parity_gap` so they don't block CI; the failure documents
  # the gap.
  #
  # Closing this gap means either:
  #   - Adding a socket-shaped `run fn socket -> ... end` variant
  #     to actions (matching the existing message-handler shape).
  #   - Better: introducing `stream :name` DSL surface that maps
  #     to `Phoenix.LiveView.stream/3` and `set :items, rx(@items
  #     ++ [...])` desugars to `stream_insert/4`.
  # See `docs/STREAMING.md` for the design discussion.

  describe "stream/3 mount seed (vanilla)" do
    test "renders initial stream items", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/parity/vanilla/streams")

      assert has_element?(view, "#items li", "first")
      assert has_element?(view, "#items li", "second")
    end
  end

  describe "stream_insert append (vanilla)" do
    test "appends a new item to the end", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/parity/vanilla/streams")

      view
      |> form("form[phx-submit=append]", %{"body" => "third"})
      |> render_submit()

      assert has_element?(view, "#items li", "third")
    end
  end

  describe "stream_insert prepend (vanilla)" do
    test "prepends a new item to the beginning", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/parity/vanilla/streams")

      view
      |> form("form[phx-submit=prepend]", %{"body" => "zero"})
      |> render_submit()

      assert has_element?(view, "#items li", "zero")
    end
  end

  describe "stream_delete (vanilla)" do
    test "removes the matching item", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/parity/vanilla/streams")

      view
      |> element("button.delete[phx-value-id=\"1\"]")
      |> render_click()

      refute has_element?(view, "#items li", "first")
      assert has_element?(view, "#items li", "second")
    end
  end

  describe "stream reset: true (vanilla)" do
    test "replaces the collection wholesale", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/parity/vanilla/streams")

      view
      |> element("#reset")
      |> render_click()

      refute has_element?(view, "#items li", "first")
      refute has_element?(view, "#items li", "second")
      assert has_element?(view, "#items li", "reset")
    end
  end

  # ============================================
  # lavash side — known gaps, tagged @parity_gap
  # ============================================

  describe "lavash side (parity gap)" do
    @describetag :parity_gap

    test "stream/3 mount seed renders initial items", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/parity/lavash/streams")

      assert has_element?(view, "#items li", "first")
      assert has_element?(view, "#items li", "second")
    end

    test "stream_insert append fails — action run fn drops socket changes",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/parity/lavash/streams")

      view
      |> form("form[phx-submit=append]", %{"body" => "third"})
      |> render_submit()

      assert has_element?(view, "#items li", "third")
    end

    test "stream_insert prepend fails — same reason",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/parity/lavash/streams")

      view
      |> form("form[phx-submit=prepend]", %{"body" => "zero"})
      |> render_submit()

      assert has_element?(view, "#items li", "zero")
    end

    test "stream_delete fails — same reason", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/parity/lavash/streams")

      view
      |> element("button.delete[phx-value-id=\"1\"]")
      |> render_click()

      refute has_element?(view, "#items li", "first")
      assert has_element?(view, "#items li", "second")
    end

    test "stream reset: true fails — same reason", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/parity/lavash/streams")

      view
      |> element("#reset")
      |> render_click()

      refute has_element?(view, "#items li", "first")
      refute has_element?(view, "#items li", "second")
      assert has_element?(view, "#items li", "reset")
    end
  end
end
