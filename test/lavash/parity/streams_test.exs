defmodule Lavash.Parity.StreamsTest do
  @moduledoc """
  Parity suite: `Phoenix.LiveView.stream/3` and friends.

  Streams are append/delete-friendly collections that ship deltas
  (rather than full lists) over the wire. Critical for chat
  histories, log tails, search-as-you-type results, and anywhere
  else where rerendering N items on every change would be
  wasteful.

  ## Lavash status

  Lavash doesn't yet expose `stream :name` as DSL surface. Both
  fixtures reach for raw `Phoenix.LiveView.stream/3`,
  `stream_insert/4`, `stream_delete/3` — but on the lavash side
  these calls live inside `run fn socket -> ... end` bodies (the
  post-cascade socket-shape op introduced by #117). The runtime
  accepts the returned socket wholesale, so the stream changes
  land correctly.

  A future `stream :name` DSL entity would let the lavash side
  collapse from imperative `run` bodies to declarative
  `push`/`delete`/`reset` ops; the parity tests below stay valid
  through that transition.
  """
  use Lavash.ConnCase, async: true

  @paths [
    {"vanilla", "/parity/vanilla/streams"},
    {"lavash", "/parity/lavash/streams"}
  ]

  for {label, path} <- @paths do
    @path path

    describe "stream/3 mount seed (#{label})" do
      test "renders initial stream items", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path)

        assert has_element?(view, "#items li", "first")
        assert has_element?(view, "#items li", "second")
      end
    end

    describe "stream_insert append (#{label})" do
      test "appends a new item to the end", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path)

        view
        |> form("form[phx-submit=append]", %{"body" => "third"})
        |> render_submit()

        assert has_element?(view, "#items li", "third")
      end
    end

    describe "stream_insert prepend (#{label})" do
      test "prepends a new item to the beginning", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path)

        view
        |> form("form[phx-submit=prepend]", %{"body" => "zero"})
        |> render_submit()

        assert has_element?(view, "#items li", "zero")
      end
    end

    describe "stream_delete (#{label})" do
      test "removes the matching item", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path)

        # Both fixtures seed id=1 ("first") at mount.
        view
        |> element("button.delete[phx-value-id=\"1\"]")
        |> render_click()

        refute has_element?(view, "#items li", "first")
        # The other item should still be present.
        assert has_element?(view, "#items li", "second")
      end
    end

    describe "stream reset: true (#{label})" do
      test "replaces the collection wholesale", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path)

        view
        |> element("#reset")
        |> render_click()

        # Original items should be gone; replacement should be present.
        refute has_element?(view, "#items li", "first")
        refute has_element?(view, "#items li", "second")
        assert has_element?(view, "#items li", "reset")
      end
    end
  end
end
