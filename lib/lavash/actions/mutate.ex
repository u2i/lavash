defmodule Lavash.Actions.Mutate do
  @moduledoc """
  Keyed mutation of a `client_state` projection row, declared once and
  evaluated on both sides.

      action :decrement, [:id] do
        mutate :items, :update_quantity,
               rx(if @item.quantity <= 1, do: :remove, else: %{quantity: @item.quantity - 1})
      end

  The `rx()` transform sees the matched row as `@item` (plus normal
  state/param refs) and returns either `:remove` or a params map:

  - **Client** (transpiled): runs against the projected row — `:remove`
    drops it, a params map merges into it. That's the instant
    prediction.
  - **Server**: runs against the authoritative record (fetched by the
    projection's key from the action's same-named param) — `:remove`
    destroys it, a params map drives the named Ash update action. The
    resource is broadcast and the backing read re-reads in the same
    event, confirming (or correcting) the prediction.

  Keep the transform to fields whose wire encoding is the identity
  (numbers, booleans, strings) — encoded fields (Decimal, dates)
  differ between the projected row and the raw record.
  """
  defstruct [
    :field,
    :action,
    :transform,
    __spark_metadata__: nil
  ]
end
