defmodule Lavash.Actions.SocketRun do
  @moduledoc """
  Executes a function with full socket access.

  Where `Lavash.Actions.Run` uses the `assigns -> assigns` shape
  (and the runtime extracts changes via `__changed__` tracking),
  `SocketRun` uses `socket -> socket`. The whole returned socket
  replaces the current socket — the action runtime trusts the
  user to call lavash's state setters (`Lavash.Socket.put_state/3`)
  or Phoenix LiveView ops (`Phoenix.LiveView.stream_insert/4`,
  `Phoenix.LiveView.allow_upload/3`, etc.) directly.

  ## When to reach for this

  Use `socket_run` for any LV-level op that's not just "mutate a
  declared state field":

    - Stream operations: `Phoenix.LiveView.stream_insert/4`,
      `stream_delete/3`, `stream/4` with `reset: true`
    - Upload operations: `Phoenix.LiveView.allow_upload/3`,
      `consume_uploaded_entries/3`, `cancel_upload/3`
    - Anything that needs to call `Phoenix.LiveView.push_event/3`
      / `push_patch/2` / `redirect/2` with logic that doesn't fit
      the declarative `navigate`/`push_event`/`redirect` ops

  For ordinary state mutation, prefer `run fn assigns -> ... end`
  — the reactive graph tracks changes precisely and downstream
  calculations recompute only when their actual deps changed.

  ## Trade-off

  `socket_run` returns a socket, so the action runtime doesn't
  know what changed. Downstream reactive recompute treats every
  field as potentially dirty (full recompute) instead of the
  precise diff `Run` enables. That's the cost of socket-level
  power — and the reason this is a separate op rather than the
  default.

  ## Execution order

  `socket_run` ops run **after** `set` and `run` ops, **before**
  `effect`, `invoke`, and `submit`. This means a sequence like:

      set :messages, rx(@messages ++ [%{role: "user", content: @input}])
      socket_run fn socket ->
        Phoenix.LiveView.stream_insert(socket, :feed, ...)
      end

  applies the `set` first (so `@messages` is up to date when the
  socket_run runs), then the socket_run.

  ## Fields

  - `:fun` — The function AST (quoted). Compiled at runtime into
    a `__lavash_socket_run__/3` clause on the user's module, same
    pattern as `Run`.
  """
  defstruct [:fun, __spark_metadata__: nil]
end
