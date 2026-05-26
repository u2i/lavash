defmodule Lavash.Actions.Run do
  @moduledoc """
  Post-cascade imperative escape hatch for actions.

  Runs AFTER the reactive cascade has settled. Takes a socket,
  returns a socket. The user can do anything — write state,
  push events, call LV stream/upload ops, hit external services,
  log — and the returned socket replaces the current one wholesale.

  ## When to use

      run fn socket ->
        # Read post-cascade derived values
        new_msg = %{id: next_id(), summary: socket.assigns.summary}

        # Do socket-level LV ops
        Phoenix.LiveView.stream_insert(socket, :messages, new_msg)
      end

  Use `run` for:

    - Socket-level LV ops that aren't pure state writes:
      `stream_insert/4`, `allow_upload/3`,
      `consume_uploaded_entries/3`, `cancel_upload/3`
    - Side effects that need the post-cascade view (logging derived
      values, sending notifications with computed content)
    - Anything that doesn't fit the declarative ops but needs
      consistent state

  ## Trade-off: no re-cascade

  A `run` body MAY mutate `socket.assigns` (via `put_state`,
  `assign/3`, or LV ops that write to the socket). Those writes
  land — Phoenix's render diff machinery picks them up via
  `__changed__` so the wire diff is correct.

  But because `run` is post-cascade, lavash does NOT re-fire the
  reactive cascade after the body. Calcs depending on what `run`
  wrote will be stale until the next user event.

  If you need a derived value of a write, write it in
  `pre_run` instead (pre-cascade; cascade then settles the derived
  values; downstream `run`s read the result).

  ## Fields

  - `:fun` - quoted AST of the `fn socket -> socket end` body.
    Compiled into a `__lavash_run__/3` clause on the user's module.
  """
  defstruct [:fun, __spark_metadata__: nil]
end
