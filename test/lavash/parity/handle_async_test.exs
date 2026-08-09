defmodule Lavash.Parity.HandleAsyncTest do
  @moduledoc """
  Parity suite: assign_async + start_async/handle_async.

  Vanilla side uses Phoenix.LiveView.assign_async/3 (for the
  AsyncResult-wrapped :report field) and start_async/3 +
  handle_async/3 (for the :fetch_count side-effect task).

  Lavash side uses `calculate :report, rx(...), async: true`
  for the AsyncResult case (a lavash-native capability since
  before this branch), and the escape hatch of a custom
  handle_async/3 for the start_async case (no declarative DSL
  for start_async + handle_async yet).
  """
  use Lavash.ConnCase, async: false

  @paths [
    {"vanilla", "/parity/vanilla/handle_async"},
    {"lavash", "/parity/lavash/handle_async"}
  ]

  # `render_async(view, timeout)` only waits for async work that has
  # ALREADY been registered — under full-suite CPU load the async can
  # start after the check, making render_async return immediately and
  # the assertion flake (issue #42). Poll with a deadline instead:
  # has_element?/3 re-renders, so the loop observes the resolution
  # whenever it lands.
  defp assert_eventually(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll_until(fun, deadline)
  end

  defp poll_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(50)
        poll_until(fun, deadline)

      true ->
        # Final call outside the rescue window so the failure message
        # comes from the actual assertion.
        assert fun.()
    end
  end

  for {label, path} <- @paths do
    @path path

    describe "assign_async → AsyncResult template branch (#{label})" do
      test "report resolves and renders", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path)
        assert_eventually(fn -> has_element?(view, "#report", "Report ready") end)
      end
    end

    describe "start_async + handle_async (#{label})" do
      test "fetch_count result lands in handle_async and assigns", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path)
        assert_eventually(fn -> has_element?(view, "#fetch-count", "42") end)
      end
    end
  end
end
