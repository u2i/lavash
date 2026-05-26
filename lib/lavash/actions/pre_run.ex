defmodule Lavash.Actions.PreRun do
  @moduledoc """
  Pre-cascade imperative escape hatch for actions.

  Runs BEFORE the reactive cascade. Takes a socket, returns a
  socket. The user is responsible for writing state via
  `Lavash.Socket.put_state/3` (or any LV-style write that updates
  `socket.assigns.__changed__`) — the action runtime extracts
  `__changed__` after the body to populate lavash's dirty set,
  so the cascade sees what changed and recomputes precisely.

  ## When to use

      pre_run fn socket ->
        # Validate / preprocess BEFORE state mutates
        if socket.assigns.form_valid? do
          Lavash.Socket.put_state(socket, :submitted, true)
        else
          raise "validation failed"  # or just return socket unchanged
        end
      end

  Use `pre_run` when you need imperative Elixir to compute a state
  value that downstream calcs depend on. The cascade fires after,
  and your write is visible to it.

  For state mutation that fits `rx()`, prefer the declarative
  `set :foo, rx(...)`. For socket-level ops that don't write
  state (push_event, stream_insert, etc.) and that want to
  observe POST-cascade state, use `run` (the post-cascade
  socket op).

  ## Fields

  - `:fun` — quoted AST of the `fn socket -> socket end` body.
    Compiled at runtime into a `__lavash_pre_run__/3` clause on
    the user's module, same pattern as `Run`/`SocketRun`.
  """
  defstruct [:fun, __spark_metadata__: nil]
end
