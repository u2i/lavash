defmodule Lavash.Parity.TerminateProbe do
  @moduledoc """
  Cross-process recorder for the terminate parity suite.

  A LiveView's `terminate/2` callback runs in the LV process,
  which exits immediately after — so any state the callback
  records lives elsewhere or it's gone. We use a public ETS
  table keyed by socket id; the test's `setup` block creates
  the table, the fixture's `terminate/2` writes to it, and the
  test's `await/2` polls for the record after triggering shutdown.

  ## Why ETS over a Registry / GenServer

  ETS is the simplest thing that survives the LV process exit
  without setup ceremony. A Registry would work but adds an
  unnecessary OTP child. A test-process mailbox would require
  the LV to know the test pid, which it doesn't.
  """

  @table :lavash_parity_terminate_probe

  @doc "Creates the ETS table. Idempotent — safe to call from any setup."
  def setup do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:public, :named_table, :set, write_concurrency: true])
        :ok

      _ ->
        :ets.delete_all_objects(@table)
        :ok
    end
  end

  @doc "Called from `terminate/2`. Idempotent on socket-id."
  def record(socket_id, reason) do
    if :ets.whereis(@table) != :undefined do
      :ets.insert(@table, {socket_id, reason})
    end

    :ok
  end

  @doc """
  Polls for a `{:terminated, reason}` record up to `timeout_ms`.

  Returns `{:ok, reason}` if found or `:timeout` otherwise.
  """
  def await(socket_id, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await(socket_id, deadline)
  end

  defp do_await(socket_id, deadline) do
    case :ets.lookup(@table, socket_id) do
      [{^socket_id, reason}] ->
        {:ok, reason}

      [] ->
        if System.monotonic_time(:millisecond) >= deadline do
          :timeout
        else
          Process.sleep(10)
          do_await(socket_id, deadline)
        end
    end
  end
end
