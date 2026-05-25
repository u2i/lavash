defmodule Lavash.Actions.PushEvent do
  @moduledoc """
  An action op that calls `Phoenix.LiveView.push_event/3` on the
  socket. Fires a client-side event for a JS hook to receive via
  `this.handleEvent("name", fn)`.

  Payload values can be literal terms or `rx(...)` expressions —
  rx values are evaluated against the action's effective state
  (state + calculations + params) at fire time.

  ## Example

      action :inc do
        set :count, rx(@count + 1)
        push_event "counter_updated", %{count: rx(@count), kind: "inc"}
      end
  """
  defstruct [:name, :payload, __spark_metadata__: nil]
end
