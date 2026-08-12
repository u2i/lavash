# Stream projections: reconciling `client_state` with LiveView streams

Design for issue #71. Status: **phase 1 (spike) implemented** — `append`
with a client id → predicted row DOM insert → server `stream_insert`
confirmation; later phases are design-only.

## The tension

`client_state` projections and LiveView streams solve list rendering
with opposite commitments:

|                | projections                      | streams                          |
|----------------|----------------------------------|----------------------------------|
| server state   | full list in assigns             | nothing retained                 |
| wire           | full list in `data-lavash-state` | per-row insert/update/delete ops |
| client state   | full copy, predictions rewrite it| the DOM **is** the state         |
| confirmation   | same-event re-read replaces list | per-row ops from the write       |
| sweet spot     | tens of rows (cart, todo)        | thousands of rows                |

Today a lavash view needing a big list drops to `run` +
`Phoenix.LiveView.stream/3` escape hatches (see
`test/support/parity/lavash/streams_live.ex`) and loses the optimistic
layer for that list entirely.

## The load-bearing insight

`phx-update="stream"` containers do **not** reconcile children on
patch — the client DOM is the source of truth and the server only
sends imperative ops. Two consequences fall out:

1. **A client-inserted row survives server patches by construction.**
   A predicted row appended to the container isn't clobbered by the
   next diff the way a `data-lavash-html` subtree would be — no merge
   walker gymnastics needed.
2. **Client-generated ids make predict and confirm the same DOM
   node.** The append op already mints a UUID that the server
   persists under (`force_change_attribute(:id, uuid)`). If the
   predicted row renders with the stream dom id (`items-<uuid>`), the
   server's confirming `stream_insert` of the written record targets
   the *same element* — LiveView morphs it in place. No temp-key
   churn, no flash, and confirmation detection is DOM-truthful: the
   server-rendered replacement doesn't carry the client's
   `data-lavash-provisional` attribute, so "the attribute is gone"
   *is* the confirmation signal.

The meeting point, then: **the client holds no list copy at all** —
predictions become row-level DOM operations against the stream
container, and the SyncedVar full-list protocol is replaced by
per-row provisional tracking.

## Design

### DSL

```elixir
read :entries, Entry, :recent do
  client_state :items do
    key :id
    fields [:id, :body, :inserted_at]
    stream true              # <- the variant
  end
end
```

`stream true` changes the projection's contract:

- **Not in assigns**: the projected list is fed to
  `Phoenix.LiveView.stream/3` at mount / read-refresh and released
  (`temporary_assigns` semantics via streams). `@items` is not
  readable in rx() — it doesn't exist.
- **Not in `data-lavash-state`**: the field is excluded from client
  state. Bounded memory on both ends.
- **Template**: the user writes the standard stream idiom —
  `<div id="items" phx-update="stream"> <div :for={{dom_id, row} <- @streams.items} id={dom_id}>`.

### Predictions become row ops

The projection-op family is *already* row-shaped — that's the part of
the existing design that transfers unchanged:

- `append :items, :create, rx(...)` — client half renders ONE row via
  the transpiled row template (see below) with the pre-stashed client
  UUID as `id="items-<uuid>"` + `data-lavash-provisional`, inserts it
  into the container (`at:`-aware), and the server half is exactly
  today's `apply_append` — except confirmation is a
  `stream_insert(socket, :items, projected_row)` of the written
  record instead of marking the read for a full re-read.
- `mutate`/`remove`/`upsert` (phase 2) — client half targets the row
  node by key (`#items-<id>`): re-render its fields / remove it /
  either; server half unchanged plus per-row `stream_insert`/
  `stream_delete` confirmation.

### The row template is its own compilation unit

`Lavash.Component.JsGenerator` already transpiles `:for` bodies into
JS template literals with the loop var in scope
(`collection.map(item => \`...\`)`). For a streamed projection the
same machinery emits the map **callback** as a standalone row
function instead of wrapping it in a list rewrite:

```js
__stream_row_items(row, domId) { return `<div id="${domId}" ...>...`; }
```

The `{dom_id, row}` tuple destructure in the template maps to
`(domId, row)` parameters. `data-lavash-html` subtree re-rendering is
**not used** for stream containers — the two `phx-update` models
don't compose, and they don't need to: per-row ops never re-render
the list.

### Per-row sync state (keyed SyncedVar)

The full-list SyncedVar disappears with the list. Phase 1 replaces it
with a keyed provisional set on the hook (`hook.streamRows:
Map<domId, {provisional: true}>`), integrated with the #72 annotation
contract:

- predicted row inserts with `data-lavash-provisional`; the hook is
  `data-lavash-syncing` while the set is non-empty
- confirmation: after each `updated()`, any tracked dom id whose
  element no longer carries the attribute (server-rendered
  replacement) — or no longer exists (server rejected/deleted) — is
  resolved

Phase 2 (mutates) generalizes this to a keyed SyncedVar variant:
per-row `{value, confirmedValue, pending}` with the same
pending-match rules as today's scalar protocol, keyed by dom id.

### Ordering and `limit:`

- The predicted insert position comes from the op's declared `at:`
  (default `-1`, append). The server's confirming `stream_insert`
  carries its own `at:` — **server order wins**: LiveView repositions
  the node if they disagree. The visible effect of a disagreement is
  the row hopping to its confirmed position on confirm, which is the
  honest rendering of "the client guessed".
- `limit:` is enforced by LiveView on server ops only, so a predicted
  insert can transiently exceed the limit by one row until the
  confirming op prunes. Documented, not fought.

### Aggregates over streamed projections

A calc over a streamed projection (`rx(length(@items))`) is a
**compile error** (the existing optimistic-strictness machinery —
the field is simply not client-visible, and not server-visible
either). The supported pattern is server-computed aggregates as
ordinary optimistic state with predicted deltas:

```elixir
state :item_count, :integer, from: :ephemeral, optimistic: true

action :add, [:body] do
  set :item_count, rx(@item_count + 1)   # predicted delta
  append :items, :create, rx(%{body: @body})
end
```

### PubSub invalidation (phase 3)

Today's invalidation re-reads the whole list. A streamed read wants
targeted ops: `Lavash.PubSub.broadcast/1` grows a per-record variant
(`{resource, :written, record}` / `{resource, :deleted, id}`) that
maps to `stream_insert`/`stream_delete` on subscribed views, falling
back to a full `stream(..., reset: true)` re-read when a broadcast
can't be attributed to a row.

## Phases

1. **Spike (this PR)**: `stream true` DSL flag; mount streams the
   projected read; `append` predicts a DOM row insert under the
   client id; server confirms via `stream_insert` from the same
   event; keyed provisional tracking wired into the #72 annotations;
   10k-row fixture + e2e proving in-window prediction and same-node
   confirmation.
2. `mutate`/`remove`/`upsert` row ops + the keyed SyncedVar variant.
3. Targeted PubSub row invalidation.
4. `at:`/`limit:` surface on the ops; ordering reconciliation tests.
