# Lavash Pipeline Architecture

## What this is

The lavash optimistic-state machinery is one orchestrated reconciliation
that crosses several concerns (overlays, forms, bindings, optimistic
actions). Today that orchestration lives inline in
`lavash_optimistic.js`'s `updated()` method.

The pipeline makes the orchestration first-class:

  - The update cycle is a sequence of **named stages**
  - Each concern is an object that **registers handlers** for the stages
    it cares about
  - A shared **`ctx`** object flows through the cycle carrying
    cross-concern observations
  - The user **opts into concerns** at the entry point — `lavash({
    concerns: [overlays, forms, bindings, optimisticActions] })`

Concerns the user doesn't include don't run, don't ship.

## Stage names

### `mounted` stages

Run once at hook mount, in this order:

  1. `init`              — core state: parse dataset, create SyncedVarStore,
                           version tracking, load generated fns, expose
                           `el.__lavash_hook__`. Owned by the pipeline
                           itself (not a concern).
  2. `mounted`           — each concern's mount-time setup: event listeners,
                           animated-state managers, fieldState init, etc.
                           Concerns run in registration order.

### `updated` stages

Run on every LV patch. The ctx is created fresh per cycle.

  1. `observeBeforeMerge` — concerns inspect SyncedVar state and write to
                            ctx BEFORE store.serverUpdate mutates it.
                            Producers: overlays (asyncFieldsReady,
                            isModalOpening, animatedPhaseFields).
  2. `capturePendingPaths` — core writes `ctx.pendingPaths` from the store.
                            Internal stage, not a concern hook.
  3. `applyStoreUpdate`  — core runs `store.serverUpdate`. Internal.
  4. `mergePayload`      — core runs the merge walker. The walker invokes
                            concern-registered **visitors** for special
                            paths (empty `_params`, `_server_errors`, etc.).
  5. `reconcileSyncedVars` — core ensures `hook.state` matches SyncedVar
                            values after the merge.
  6. `versionBookkeeping` — core updates `hook.serverVersion` /
                            `hook.clientVersion`.
  7. `notifyAfterMerge`  — concerns run post-merge notifications.
                            overlays: notifyAsyncReadyForFields,
                            notifyDelegatesUpdated.
  8. `afterRecompute`    — runs after `hook.recomputeDerives()`. Concerns
                            do post-recompute work. forms: re-seed form
                            params from DOM.
  9. `afterRender`       — runs after `hook.updateDOM()`. Concerns do
                            post-render fixups. Core: restore pending
                            input values that updateDOM may have
                            overwritten.

### `destroyed` stages

  1. `destroyed`         — each concern's teardown: listener removal,
                           preserved-state stash, etc. Concerns run in
                           **reverse** registration order (mirror of
                           mounted).

### `beforeUpdate` (Phoenix lifecycle, distinct from updated)

  1. `beforeUpdate`      — concerns participate in FLIP-capture work.
                           overlays: captureBeforeUpdate.

## ctx schema

Created fresh at the top of each `updated()` cycle. Disposed at the end.
Lives only for one cycle.

```js
{
  // ----- Inputs (set by pipeline before any stage runs) -----
  serverState:         object,    // raw incoming server payload
  newServerVersion:    integer,   // parsed from data-lavash-version
  module:              string,    // hook module name (for debug logs)

  // ----- Produced by `observeBeforeMerge` (overlays) -----
  asyncFieldsReady:    string[],  // fields that just transitioned to ok
  isModalOpening:      boolean,   // any animated field in entering/loading
  animatedPhaseFields: Set<string>, // phase fields to skip in merge

  // ----- Produced by `capturePendingPaths` (core) -----
  pendingPaths:        Set<string>, // paths still in flight client-side

  // ----- Produced by `mergePayload` (core via walker) -----
  changedFields:       string[],  // top-level fields mutated by merge
  clearedParamsFields: Set<string>, // params fields fully reset this cycle

  // (Concerns can attach arbitrary fields. Convention: namespace under
  // ctx.<concernName>.<field> to avoid collisions.)
}
```

## Concern interface

A concern is a plain object with these optional properties:

```js
{
  // Required: short name. Used for ctx namespacing and debug logs.
  name: "overlays",

  // Optional lifecycle hooks. Each receives (hook, ctx) where ctx is
  // null for mounted/destroyed (no per-cycle context).
  mounted:            (hook, ctx) => void,   // ctx = null
  destroyed:          (hook, ctx) => void,   // ctx = null
  beforeUpdate:       (hook, ctx) => void,   // ctx = null (Phoenix lifecycle, not part of update cycle)

  // Update-cycle stages. ctx is the per-cycle object.
  observeBeforeMerge: (hook, ctx) => void,
  notifyAfterMerge:   (hook, ctx) => void,
  afterRecompute:     (hook, ctx) => void,
  afterRender:        (hook, ctx) => void,

  // Optional: visitors registered with the merge walker.
  // Keys are pattern names; values are visit functions.
  mergeVisitors: {
    emptyParams: (hook, ctx, { key, path, formName, hasPendingChild }) => void,
    serverErrors: (hook, ctx, { key, path, formName, hasPendingChild }) => boolean,
    // etc.
  }
}
```

Concerns omit any property they don't need. The pipeline runner checks
`if (concern.observeBeforeMerge) concern.observeBeforeMerge(hook, ctx)`.

## Merge walker visitor protocol

The merge walker is procedural code that traverses the incoming server
payload. At certain decision points it consults visitors:

- **`emptyParams`** — fired when we hit `{form}_params: {}` at the top
  level. The visitor decides what to do (clear pending paths, clear
  fieldState). Forms registers this.

- **`serverErrors`** — fired when we hit `{form}_server_errors: {}` at
  the top level. The visitor returns `true` to skip the clear (e.g.
  because params for that form are still pending). Forms registers this.

- **`animatedPhaseField`** — fired at every top-level key. The visitor
  returns `true` if the key should be skipped (server's stale phase
  value shouldn't overwrite client's phase machine). Overlays
  registers this.

The walker iterates `ctx.concerns` looking for `mergeVisitors[name]`
entries. A pattern with no registered visitor falls back to default
behaviour (do nothing for emptyParams; clear for serverErrors; merge
normally for animatedPhaseField).

## Decorator factory

```js
import { lavash } from "lavash";
import { forms, overlays, bindings, optimisticActions } from "lavash/concerns";

// Create the lavash decorator with the concerns you want
const lavashDecorator = lavash({
  concerns: [optimisticActions, bindings, forms, overlays]
});

// Apply to all your hooks
const decoratedHooks = decorate(myHooks, [lavashDecorator]);

// Wire into LiveSocket
const liveSocket = new LiveSocket("/live", Socket, {
  hooks: decoratedHooks,
  params: () => ({ _csrf_token: csrf, _lavash_state: getState() })
});
```

Order of concerns in the array IS the order they run at each stage.
Within `mounted`, runs in array order. Within `destroyed`, runs in
reverse array order. Within update-cycle stages, runs in array order.

## What stays on the hook

The decorator wraps the user's hook. After wrapping, the hook still has:

  - `state`, `store`, `clientVersion`, `serverVersion`, `fns`, `graph`
    — core state set by the pipeline's `init` stage
  - `recomputeDerives()`, `updateDOM()`, `setStateAtPath()`,
    `getStateAtPath()`, `syncUrl()` — methods called by concerns
  - `refreshFromParent()`, `propagateBoundFieldsToParent()`,
    `runOptimisticAction()` — methods called by other hooks (external
    contract). Thin delegators to concerns.

Concerns can stash their per-instance state under `hook._<concernName>`
to namespace cleanly (e.g. `hook._forms = { fieldState, submittedForms,
listeners }`). This will matter more when concerns are composed onto
hooks that already have their own `this`-state.

## Non-goals

- We are NOT trying to make every kind of side effect a concern. Global
  window listeners (`phx:_lavash_sync`) stay as module-init side
  effects, not concerns.

- We are NOT trying to make user code a concern. User hooks have their
  own `mounted/updated/destroyed`; the lavash decorator wraps those.

- We are NOT inventing more stages than the current `updated()` needs.
  Stages are observed from existing code, not speculatively added.
