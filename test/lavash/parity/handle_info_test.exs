defmodule Lavash.Parity.HandleInfoTest do
  @moduledoc """
  Parity suite: `handle_info/2` features.

  Both sides write the same custom `handle_info/2` clauses today —
  the DSL doesn't have a declarative surface for receive-side
  message dispatch yet. A future `handle_info do on :foo do ...
  end end` block would close the gap.
  """
  use Lavash.ConnCase, async: false

  @paths [
    {"vanilla", "/parity/vanilla/handle_info"},
    {"lavash", "/parity/lavash/handle_info"}
  ]

  # has_element? is robust to the rendering difference between
  # vanilla (`<p id="ticks">1</p>`) and lavash (which auto-wraps
  # bare `{@field}` in `<span data-lavash-display="..">..</span>`,
  # so the rendered HTML is `<p id="ticks"><span ..>1</span></p>`).

  for {label, path} <- @paths do
    @path path

    describe "self-scheduled tick (#{label})" do
      test "Process.send_after delivers to handle_info", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path)
        view |> element("#schedule") |> render_click()
        Process.sleep(100)
        assert has_element?(view, "#ticks", "1")
      end
    end

    describe "self-sent custom message (#{label})" do
      test "send/2 to self() reaches handle_info", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path)
        view |> element("#self-send") |> render_click()
        Process.sleep(50)
        assert has_element?(view, "#last-msg", "hello")
      end
    end

    describe "PubSub broadcast (#{label})" do
      test "broadcast to subscribed topic increments counter", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path)
        view |> element("#broadcast") |> render_click()
        Process.sleep(50)
        assert has_element?(view, "#broadcasts", "1")
      end
    end
  end
end
