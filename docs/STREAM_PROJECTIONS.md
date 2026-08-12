# Stream projections: reconciling `client_state` with LiveView streams

Design for issue #71. Status: **phases 1–4 implemented** — the full
projection-op family (`append`/`mutate`/`remove`/`upsert`) predicts
per-row DOM operations confirmed by same-event stream ops; targeted
PubSub row invalidation; `at:`/`limit:` ordering.

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
- `mutate` — the client addresses the row node by key
  (`#items-<id>`), reads its current data back from the injected
  `data-lavash-row` JSON (see below), runs the transform with `@item`
  bound, and replaces the node with a re-render (or drops it on
  `:remove`). The server confirms with `stream_insert` of the updated
  record / `stream_delete`.
- `remove` — the client drops the node immediately; the confirming
  `stream_delete` no-ops on the already-gone element, so the
  prediction resolves when the event's patch (version bump) arrives.
- `upsert` — the client scans the container's rows' `data-lavash-row`
  payloads for a match: conflict re-renders that row, miss inserts
  under the pre-stashed client id exactly like append. The server
  side can't match against `state[read]` (it's `:streamed`) — it
  requeries the match through the backing read action
  (`read_one_through/4`), so the read's filters apply.

### Row data rides the row (`data-lavash-row`)

Keyed predictions need the row's current values, but no list copy
exists. The row element itself carries them: a token transformer
injects `data-lavash-row={Lavash.JSON.encode!(row)}` onto the stream
`:for` element, and the generated row function renders the same
attribute on predicted rows. Injection is need-driven — only
projections targeted by a `mutate`/`upsert` pay the per-row payload;
append/remove-only lists stay lean.

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

- `at:` lives on the **projection** (`at 0` prepends, default `-1`
  appends) — one ordering per list, used by both the client's
  predicted insert (`afterbegin`/`beforeend`) and the server's
  confirming stream ops. On disagreement (e.g. another session's
  interleaved write) **server order wins**: LiveView repositions the
  node on confirm — the honest rendering of "the client guessed".
- `limit:` (also on the projection) is enforced by LiveView on server
  ops only, so a predicted insert can transiently exceed the limit by
  one row until the confirming op prunes. Documented, not fought.

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

### Targeted PubSub invalidation

Writes to streamed projections broadcast record-level detail —
`Lavash.PubSub.broadcast_record(resource, {:written, id} | {:deleted,
id})` — instead of the coarse resource message. A subscribed view
with a streamed projection of that resource requeries JUST the
touched record **through its backing read** (so the read's filters
decide membership): found → `stream_insert`, not found (deleted, or
outside the filter) → `stream_delete`. Non-streamed reads on the
same resource still coarse-invalidate, and plain 2-tuple broadcasts
keep the old behavior (streamed reads re-stream with `reset: true`).

## Status

All four phases are implemented and covered by
`test/integration/stream_projection_test.exs`: streamed-not-shipped,
per-op prediction/confirmation (append, mutate, remove, both upsert
branches), targeted cross-process row ops with filter correctness,
`at 0` prepend ordering, `limit` pruning, and the 10k-row fixture.

Remaining follow-ups (not blocking): a full keyed SyncedVar protocol
for per-row pending semantics beyond the provisional marker,
`async: true` streamed reads, and issue #96 — browser-layer stream
row removals (delete-only/reset diffs) intermittently not applying in
the e2e harness; cross-session removals route through reset
re-streams and their server semantics are pinned at the LiveViewTest
level meanwhile.
