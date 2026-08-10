# Action lifecycle

How a lavash action runs from event arrival to render.

## The four phases

```
EVENT ARRIVES (phx-click, phx-submit, etc.)
      │
      ▼
┌─────────────────────────────────┐
│  PRE-CASCADE                    │
│    set :foo, rx(...)            │  declarative state writes
│    pre_run fn socket -> socket  │  imperative pre-cascade hook
│    mutate/remove/append         │  client_state projection writes
└─────────────────────────────────┘
      │  marks fields dirty
      ▼
┌─────────────────────────────────┐
│  CASCADE                        │
│    Reactive.recompute(socket)   │  one pass through the dep graph
└─────────────────────────────────┘
      │  all calcs settled; state consistent
      ▼
┌─────────────────────────────────┐
│  POST-CASCADE                   │
│    run fn socket -> socket end  │  imperative; reads settled state
│    effect fn socket -> :ok end  │  fire-and-forget side effects
│    submits                      │  form submission (async)
│    flashes                      │  declarative; reads settled state
│    navigates                    │
│    push_patches                 │
│    redirects                    │
│    push_events                  │
│    URL sync (push_patch)        │
│    lavashState sync (push_event)│
└─────────────────────────────────┘
      │
      ▼
RENDER (Phoenix's diff machinery reads assigns.__changed__)
```

## The invariant

**One cascade per action.** Pre-cascade mutates; cascade settles; post-cascade
observes and emits. The cascade is the consistency boundary; everything after
it reads a settled view.

Post-cascade ops *can* mutate state (via `put_state`, `assign/3`, or LV
socket ops like `stream_insert`). Those mutations land in `socket.assigns`
and update Phoenix's `__changed__` for the render diff. But **they do not
trigger a second cascade.** Calcs depending on post-cascade writes are
stale until the next event.

This is intentional. If you need a derived value from a write, write it
pre-cascade.

## Picking an op

```
Are you writing a declared state field with a simple expression?
  → set :foo, rx(...)

Are you writing a declared state field but need imperative Elixir to
compute the value, AND you want downstream calcs to recompute?
  → pre_run fn socket ->
      Lavash.Socket.put_state(socket, :foo, computed_value)
    end

Are you doing a socket-level LV op (stream_insert, allow_upload,
consume_uploaded_entries, push_event with derived payload)?
  → run fn socket ->
      Phoenix.LiveView.stream_insert(socket, :feed, ...)
    end

Are you firing a pure side effect (log line, external API call,
PubSub broadcast)?
  → effect fn socket -> :ok end

Are you emitting one of lavash's declarative side-effect kinds?
  → flash :info, "saved"
  → navigate "/somewhere"
  → push_event "name", %{}
  → push_patch "?tab=overview"
  → redirect to: "/login"
```

## Three trackers, three purposes

There are three change-tracking systems running in any lavash module. They
serve different consumers and don't need to be conflated:

| Tracker | Owned by | Written by | Read by | Purpose |
|---|---|---|---|---|
| `assigns.__changed__` | Phoenix | Every `assign/3` call (including `put_state` transitively) | Phoenix's LV render differ | Tiny wire diffs |
| `private[:lavash].dirty` | Lavash | `Lavash.Socket.put_state/3` | `Reactive.recompute/1` | Cascade is selective |
| `url_changed` / `socket_changed` flags | Lavash | `put_state` on `from: :url` / `from: :socket` fields | `maybe_push_patch` / `maybe_sync_socket_state` | Sync events fire only on real change |

The user mostly doesn't need to think about these. The contract is:

- Pre-cascade ops should write via `put_state` (or `set :foo, rx(...)`,
  which uses `put_state` underneath) so the dirty set is populated and
  the cascade is precise.
- Post-cascade ops can write however — `put_state`, raw `assign/3`,
  `stream_insert/4`. Phoenix's `__changed__` will track the assign-level
  writes for the render diff regardless; lavash's dirty set doesn't matter
  post-cascade because there's no further cascade in this event.

## Why post-cascade re-settling doesn't make sense

The cascade is a function from `(state, calc rules) → derived view`. It's
pure: same state, same derived view. If post-cascade ops *don't* mutate
state, the cascade is already at its fixed point — re-running is a no-op.
If post-cascade ops *do* mutate state, you've broken the model: the
"settled view" the post-cascade ops were supposed to observe wasn't really
settled.

So: **post-cascade is observe-and-emit.** State mutation post-cascade is
allowed (because banning it would prevent stream/upload ops) but it
explicitly does NOT propagate through calcs in the same event. Users who
need a derived value of a write should write pre-cascade.

## Mapping to the four scenario framing

| Scenario | Description | Op |
|---|---|---|
| 1 | Not using reactivity at all | `use Lavash.LiveView.Base` — no calcs, no cascade work |
| 2 | Fully reactive | `set :foo, rx(...)` + `calculate :bar, rx(...)` |
| 3 | Reactivity-compatible escape | `pre_run fn socket -> put_state(...) end` |
| 4 | Non-reactive escape | post-cascade `run` (socket-level) or `effect` (side effect) |

Scenarios 1–3 happen pre-cascade. Scenario 4 happens post-cascade. The
position in the pipeline matches the contract.

## The historical artifact: `__changed__` extraction

Earlier versions of lavash had `run fn assigns -> assigns end` as the
imperative escape hatch. The action runtime extracted `__changed__` after
the body returned and synthesized `put_state` calls for each changed
field — so users could write raw `assign/3` and lavash would populate
its dirty set retroactively.

In the post-cascade model that's unnecessary: post-cascade is observe-
and-emit, so we don't need to populate the dirty set after the body
runs. Phoenix's `__changed__` handles the render diff regardless.

`pre_run` still benefits from the safety net — a user who calls raw
`assign/3` in a pre-run body gets the assign written but not marked
dirty for the cascade. Whether the runtime extracts `__changed__` from
pre-run bodies as a fallback is a small design choice. The principled
answer is "no, you should use `put_state`," but the friendly answer is
"yes, as a safety net so users don't footgun themselves."

## Current status

This document describes the **target** design. The current implementation:

- Has the cascade-before-side-effects ordering correct (commit `e00008c`).
- Does NOT yet have `pre_run` as a separate op. Today's `run fn assigns
  -> assigns end` lives in the pre-cascade slot and is change-tracked.
- Does NOT yet have post-cascade `run`. Today's `socket_run` (commit
  `b2a3e29`) is post-cascade in spirit but ordered alongside the other
  state-mutating ops.
- The full collapse — `pre_run` + post-cascade `run` (replacing
  `socket_run`) + dropping the assigns-shape `run` — is task #117,
  pending.
