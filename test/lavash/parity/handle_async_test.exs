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

  for {label, path} <- @paths do
    @path path

    describe "assign_async → AsyncResult template branch (#{label})" do
      test "report resolves and renders", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path)
        render_async(view, 500)
        assert has_element?(view, "#report", "Report ready")
      end
    end

    describe "start_async + handle_async (#{label})" do
      test "fetch_count result lands in handle_async and assigns", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path)
        render_async(view, 500)
        assert has_element?(view, "#fetch-count", "42")
      end
    end
  end
end
