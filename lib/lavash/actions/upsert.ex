defmodule Lavash.Actions.Upsert do
  @moduledoc """
  Match-based insert-or-update of a `client_state` projection row —
  the primitive for lists with a *semantic* identity distinct from
  the row id (a cart keyed by product, a reaction keyed by user).

      action :add_item, [:product_id, :qty] do
        upsert :items,
          match: [:product_id],
          on_conflict: {:update_quantity, rx(%{quantity: @item.quantity + @qty})},
          on_insert:
            {:create_row,
             rx(%{cart_id: @cart_id, product_id: @product_id, quantity: @qty})}
      end

  One declaration, evaluated on both sides:

  - **Client** (transpiled): look up the projected row whose `match`
    fields equal the action's params/state values. Found → apply
    `on_conflict` as a merge (`@item` bound to the matched row;
    `:remove` drops it). Not found → append an `on_insert` row under
    a client-generated id (shared with the server via the event
    payload, so the row keeps its identity when the re-read lands).
  - **Server**: scan the backing read's current records by the same
    `match` fields. Found → the `on_conflict` params drive the named
    Ash update action (`:remove` destroys). Not found → the
    `on_insert` attrs drive the named Ash create action, under the
    client's id. Broadcast + same-event re-read as with the sibling
    ops.

  Compared to `append`, `upsert` predicts the *merge* when the row
  already exists — no provisional-row flicker followed by a server
  dedup collapsing it.

  ## Residual uncertainty (inherent, not implementation gaps)

  - **Branch divergence**: client and server decide the branch from
    their own copies of the list, so a raced write from another
    session can make them disagree (client predicts insert, server
    merges). The same-event re-read corrects it.
  - **Server-derived fields**: values the server re-derives at write
    time (price snapshots) can correct the client's claim.

  Because of these, upsert actions apply provisionally (seeded, not
  pending) like `append`. The dedup rule lives in the lavash action —
  a non-lavash caller writing the resource directly bypasses it, so
  back the semantic identity with an Ash `identity`/unique constraint
  when duplicates must be impossible.
  """
  defstruct [
    :field,
    :match,
    :on_conflict,
    :on_insert,
    __spark_metadata__: nil
  ]
end
