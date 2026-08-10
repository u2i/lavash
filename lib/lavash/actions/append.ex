defmodule Lavash.Actions.Append do
  @moduledoc """
  Optimistic insert into a `client_state` projection.

      action :add, [:name] do
        append :items, :create, rx(%{cart_id: @cart_id, name: @name, quantity: 1})
      end

  The `rx()` transform sees state fields and the action's params as
  `@refs` and returns the new row's attributes:

  - **Client** (transpiled): the returned map becomes a *provisional*
    row — it gets a temp key and is appended without marking the list
    pending, so the very next server push (the same event's re-read,
    carrying the real record) replaces it instead of being rejected.
  - **Server**: the returned map is filtered to the named create
    action's accepted attributes and drives `Ash.create`. The
    resource is broadcast and the backing read re-reads in the same
    event.

  Because the provisional row is rendered before the server responds,
  it should carry every field the template reads (the projection
  shape), not just the create params.
  """
  defstruct [
    :field,
    :action,
    :transform,
    __spark_metadata__: nil
  ]
end
