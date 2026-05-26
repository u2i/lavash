defmodule Lavash.Parity.TerminateTest do
  @moduledoc """
  Parity suite: `terminate/2`.

  `terminate/2` is an optional `Phoenix.LiveView` callback that
  lavash passes through unchanged — `use Lavash.LiveView` does
  `use Phoenix.LiveView` and doesn't define the callback, so a
  user-supplied `def terminate/2` reaches the runtime as-is.

  This test locks that down: if a future transformer ever shadows
  the callback (by emitting its own non-overridable definition),
  the test fails and you know where to look.

  ## Why no format_status/2

  `Phoenix.LiveView` doesn't expose `format_status/2` as a per-view
  callback. The LV runs inside `Phoenix.LiveView.Channel`, which
  defines its own `format_status/2`. A user-supplied
  `def format_status/2` on an LV module would never be invoked, so
  there's no parity assertion to make.
  """
  use Lavash.ConnCase, async: false

  alias Lavash.Parity.TerminateProbe

  setup do
    TerminateProbe.setup()
    # The LV channel links to the calling test process; `GenServer.stop`
    # on the view propagates that exit unless we trap.
    Process.flag(:trap_exit, true)
    :ok
  end

  @paths [
    {"vanilla", "/parity/vanilla/terminate"},
    {"lavash", "/parity/lavash/terminate"}
  ]

  for {label, path} <- @paths do
    @path path

    describe "terminate/2 (#{label})" do
      test "fires when the LV process exits normally", %{conn: conn} do
        {:ok, view, html} = live(conn, @path)

        # Extract the socket id from the rendered DOM. Both
        # fixtures emit it inside `<p id="socket-id">...</p>` so
        # the test can address records in the probe table.
        socket_id =
          case Regex.run(~r/<p id="socket-id">([^<]+)<\/p>/, html) do
            [_, id] -> String.trim(id)
            _ -> raise "no socket id rendered: #{html}"
          end

        assert socket_id != ""

        # Trigger a clean exit by stopping the view.
        GenServer.stop(view.pid, :shutdown)

        # Probe should observe the terminate callback.
        assert {:ok, reason} = TerminateProbe.await(socket_id, 1_000)
        assert reason == :shutdown
      end
    end
  end
end
