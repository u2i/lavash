# Lavash Architecture: The 4-Layer Model

## Intro

Lavash is best understood as four orthogonal-ish concerns stacked on top of each
other. Each layer has a self-contained value proposition and could, in
principle, be consumed without the layers above it. In practice today the
boundaries leak a little — this doc inventories every file, tags it with a
primary layer, and lists the back-edges where a lower layer reaches up into a
higher one.

The four layers are:

1. **base** — Spark DSL + vanilla LV plumbing. The DSL surface (`mount`,
   `messages`, `actions`, `when_connected`, components, slots) wired straight
   onto Phoenix LiveView. No reactivity, no client state, no optimism.
2. **state** — declarative persistence/sync for `state :foo, from: ...` fields.
   Server is always authoritative; the client carries a single global
   `lavashState` object across reconnects via the `_lavash_state` connect
   param.
3. **rx** — server-side reactive graph. `calculate :foo, rx(...)`, topological
   recomputation, async derivations. Results flow through normal LV diffs.
4. **optimism** — client-side optimistic UX. `optimistic: true`, JS-transpiled
   `rx()`, `SyncedVar`, the merge walker, version dance, phase machine,
   `data-lavash-*` DOM annotations, and the `optimistic_actions` concern.

The goal of this doc is to make scope-of-change questions tractable. If you're
chasing a layer-3 (rx) bug, this doc tells you which files are in the blast
radius and which are not.

---

## Layer Charters

### Layer 1 — base

**What it is.** The Spark DSL surface that maps to vanilla Phoenix.LiveView
constructs: `mount do`, `messages do message ... end end`, `actions do action
... end end` with imperative bodies, `template do ~H"..."` blocks,
`when_connected`, `on_mount`, `async`/`fire`,
components (`prop`, `slot`), and the seven-step transformer pipeline
(`TokenizeTemplate` → `AnalyzeTemplate` → `ExtractColocatedJs` →
`CompileComponent`/`CompileLiveView`, plus `ValidateDsl` / `ValidateTemplate`).

**What it isn't.** Anything to do with derived computation, optimistic updates,
or client state. A state field at this layer is `socket.assigns`; an action is
`def handle_event/3` written declaratively.

**Value if you stopped here.** You'd get a Phoenix.LiveView whose
`handle_event`s, `mount`, `handle_info`, etc. are declared in a uniform op
vocabulary (`set`, `run`, `effect`, `submit`, `navigate`, `fire`, `flash`,
`push_event`, `push_patch`, `redirect`), with cross-validation of `phx-click`
event names against declared actions, params against declared args, and
template `@field` references against declared state. That alone is worth a
real chunk of the README.

### Layer 2 — state

**What it is.** A declaration of where a piece of state comes from and where
its mutations should propagate to: `state :foo, :type, from: :url | :socket |
:session | :assigns | :ephemeral`. Server-side: `Lavash.Socket.put_state` is
the central write path; it writes to assigns, marks dirty, and trips
`url_changed`/`socket_changed` flags. Hydration happens at mount via
`State.hydrate_url`, `hydrate_session`, `hydrate_socket`. Client-side: a single
flat `lavashState` global, the `phx:_lavash_sync` event listener, `getState()`
for `connect_params`, and `history.replaceState` for URL pushing.

**What it isn't.** Reactive. There's no dependency graph here. There's no
client-side eval. Setting a state field just writes to assigns and Phoenix's
diff machinery takes care of the DOM. The `lavashState` object is structurally
flat — no version tracking, no pending state, no optimism.

**Value if you stopped here.** Phoenix LiveView with declarative URL params,
session integration, and reconnect-survival for socket state. No reactive
graph, no optimistic UX, but a real ergonomic win over wiring those things by
hand.

### Layer 3 — rx

**What it is.** The reactive dependency graph engine. `calculate :foo,
rx(@x + @y)` captures both source and AST. `Lavash.Reactive` builds a graph
(topological order, forward and reverse indices, compute fns), stores it on the
socket at init, and recomputes only affected derives whenever a state field
changes. Supports `async: true` derives. All eval happens server-side; results
flow through normal LV diffs.

**What it isn't.** Anything to do with the client. The JS transpiler
(`Lavash.Rx.Transpiler`) is purely a layer-4 concern — at layer 3, `rx()` is
just an Elixir expression captured for server evaluation. No optimism, no JS.

**Value if you stopped here.** A Phoenix LiveView with `calculate`d fields
that auto-update when their dependencies change, including async load
patterns. `Lavash.LiveView.Explicit` already demonstrates this is consumable
standalone — `use Lavash.LiveView.Explicit` gives you the reactive engine
without the full DSL or any optimism.

### Layer 4 — optimism

**What it is.** Client-side instant-feedback UX. `optimistic: true` /
`animated: ...` on state fields and calculations causes the rx transpiler to
emit JS, the `ExtractColocatedJs` transformer to write per-module
`.colocated.js` files, and the `LavashOptimistic` hook (decorated via the
`lavash()` pipeline) to mount a per-hook reactive store (`SyncedVar`,
`ReactiveStore`). The `optimistic_actions` concern intercepts `phx-click` and
runs the JS-side `rx()`. `SyncedVar` carries `version` / `confirmedVersion` /
`isPending` / `_closeProtection` for the merge walker to reconcile against
server pushes. Forms and bindings concerns ride on the `SyncedVar` store too,
but primarily for bookkeeping (so server echoes don't clobber in-flight typing
or pending toggles). Phase machine (`idle/entering/loading/visible/exiting`)
for animated overlays. `data-lavash-*` DOM annotations
(display, toggle, member, visible, enabled, html, errors, status, etc.).

**What it isn't.** The state of record. Optimism is a UX shim — the server is
still authoritative. Strip it out and the app still works, just with a
round-trip-latency feel.

**Value if you stopped here.** Lavash's headline feature: declarative
optimistic UX with version reconciliation, animated overlays, and a uniform
DOM-annotation vocabulary.

---

## Server Module Inventory (Elixir)

Layer column key: **B**=base, **S**=state, **R**=rx, **O**=optimism. `B/S`
means "primarily B, but writes to S" or similar — see notes.

### Top-level

| File | Layer | Notes |
| --- | --- | --- |
| `lib/lavash.ex` | B | Public namespace; module-level docs, top-level `set/3` re-export to `Socket.put_state`. |
| `lib/lavash/application.ex` | B | OTP application module (currently only reads `:pubsub` config). |
| `lib/lavash/json.ex` | O | JSON encoder for client-bound state (tuples → arrays, atoms → strings). Used only on the optimistic transport. |
| `lib/lavash/pub_sub.ex` | B | Cross-process resource invalidation broadcasts on form submit. Layer-1 plumbing for Ash forms. |
| `lib/lavash/type.ex` | S | Bidirectional URL ↔ Elixir conversion. Pure layer-2 — needed for URL hydration and `_lavash_sync` payload encoding. |
| `lib/lavash/graph.ex` | R | Pure graph algorithms (BFS reachability, topo sort). Used by rx graph, the colocated transformer's JS metadata, and the JS hook. |
| `lib/lavash/assigns.ex` | B/S | Projects metadata into assigns (form metadata, component state propagation, `__lavash_parent_version__`). The version-reading line is a back-edge into layer 4. |
| `lib/lavash/extend_errors.ex` | B | DSL entity for custom error checks; transpiled to JS by layer 4 `ValidationJs`. Spec lives at base. |
| `lib/lavash/read.ex` | B | DSL entity for Ash resource loading. |
| `lib/lavash/resource.ex` | B | Ash extension; declares fine-grained PubSub invalidation. |
| `lib/lavash/tag_engine.ex` | B | Thin wrapper around `Phoenix.LiveView.TagEngine.{Parser, Compiler}` with a `:token_transformer` hook. Pure compile-time plumbing. |
| `lib/lavash/token_transformer.ex` | B | Behaviour for token-tree transformers. |

### DSL surface

| File | Layer | Notes |
| --- | --- | --- |
| `lib/lavash/dsl.ex` | B | The Spark DSL extension for `Lavash.LiveView`. Pulls in all transformers — registers layer-4 transformers (`ExpandAnimatedStates`, `ExpandDefrx`, `ExtractColocatedJs`) directly. |
| `lib/lavash/dsl_helpers.ex` | B | `state(:field)` / `result(:derive)` reference helpers for DSL bodies. |
| `lib/lavash/dsl/common_entities.ex` | B | Shared entity schemas across LV / Component DSLs. Schema lists `optimistic:` and `animated:` options — layer-1 declares the surface that layer-4 consumes. |
| `lib/lavash/dsl/graph.ex` | R | Bridge from Spark DSL metadata → `%Lavash.Rx.Graph{}`; caches in persistent_term. |

### Socket and runtime

| File | Layer | Notes |
| --- | --- | --- |
| `lib/lavash/socket.ex` | S+O | Central write path: `put_state`, `put_derived`, dirty set, `url_changed`/`socket_changed` flags. Also owns `optimistic_version` / `bump_optimistic_version` — irreducibly straddles layers 2 and 4. The optimistic-version fields could be split into a layer-4 sidecar; the put_state/put_derived/dirty/changed mechanics are pure layer 2. |
| `lib/lavash/state.ex` | S | URL/session/socket hydration; `_lavash_state` connect param parsing. Pure layer 2. |
| `lib/lavash/state/state_field.ex` | S/O | `%Lavash.State.Field{}` struct. Carries `:optimistic` and `:animated` fields — layer-4 concepts that ride on a layer-2 struct. |
| `lib/lavash/state/url_field.ex` | S | |
| `lib/lavash/state/socket_field.ex` | S | |
| `lib/lavash/state/ephemeral_field.ex` | S | |
| `lib/lavash/state/form_field.ex` | S | Ephemeral state with form-param sync behaviour. |

### Reactive engine

| File | Layer | Notes |
| --- | --- | --- |
| `lib/lavash/reactive.ex` | R | Public reactive builder API; `init`, `put`, `recompute`, `handle_async`. The "vanilla LV" entry point for the rx engine. |
| `lib/lavash/reactive/graph_macro.ex` | R+O | `defgraph` macro: defines a graph AND transpiles `rx()` to colocated JS for client-side optimistic updates. Straddles layers 3 and 4. |
| `lib/lavash/rx/rx.ex` | R | `rx/1` macro; captures source + AST. |
| `lib/lavash/rx/graph.ex` | R | `%Lavash.Rx.Graph{}` struct: topo order, deps, dependents, compute fns, tags. |
| `lib/lavash/rx/cache.ex` | R | `persistent_term` cache of compiled rx AST → fn. |
| `lib/lavash/rx/functions.ex` | R | `defrx` reusable functions. |
| `lib/lavash/rx/string.ex` | R | String helpers callable from `rx()` (also JS-transpilable). |
| `lib/lavash/rx/transpiler.ex` | O | Elixir AST → JS. Lives under `rx/` but is purely layer 4. |

### Optimism

| File | Layer | Notes |
| --- | --- | --- |
| `lib/lavash/optimistic.ex` | O | Namespace + docs. |
| `lib/lavash/optimistic/action_js.ex` | O | Shared "is this action optimistic?" check + JS generation. |
| `lib/lavash/optimistic/action_macro.ex` | O | `optimistic_action` for components. |
| `lib/lavash/optimistic/macros.ex` | O | `optimistic_action/3` for LiveViews. |
| `lib/lavash/optimistic/transformers/expand_animated_states.ex` | O | Expands `animated: true` to phase state + visible/animating calcs. |
| `lib/lavash/optimistic/transformers/expand_defrx.ex` | O | Inlines defrx calls in rx ASTs so the transpiler can see through them. |
| `lib/lavash/optimistic/transformers/extract_colocated_js.ex` | O | The big one: emits per-module JS for actions, calculations, attr/subtree derives, form validation. |

### LiveView wiring

| File | Layer | Notes |
| --- | --- | --- |
| `lib/lavash/live_view.ex` | B | `use Lavash.LiveView`; wires DSL, template macros, optimistic hook. |
| `lib/lavash/live_view/explicit.ex` | R | Non-DSL entry for the reactive engine. Pure layer 3 — explicitly excludes optimism. |
| `lib/lavash/live_view/runtime.ex` | B+S+R+O | The runtime. Mount/handle_params/handle_event/handle_info pipeline; calls hydrate (layer 2), `Reactive.recompute` (layer 3), and `wrap_render` (layer 4). This is necessarily a multi-layer module — it's the place all four converge. |
| `lib/lavash/live_view/compiler.ex` | O | `collect_optimistic_fields`, `generate_optimistic_actions`, synthetic setter actions for optimistic state. |
| `lib/lavash/live_view/components.ex` | B+O | Form components with daisyUI classes; uses `data-lavash-*` attrs for client validation. Layer-1 helpers but coupled to layer-4 attribute vocabulary. |
| `lib/lavash/live_view/helpers.ex` | O | `optimistic_state/2` — extracts the client-state payload from assigns. |
| `lib/lavash/live_view/transformers/compile_live_view.ex` | B | Generates `mount/3`, `render/1`, `handle_params/3`, etc. via `Transformer.eval`. Wires `@after_compile` callbacks for cache erasure (layers 3 + 4). |

### Component wiring

| File | Layer | Notes |
| --- | --- | --- |
| `lib/lavash/component.ex` | B | `use Lavash.Component`. |
| `lib/lavash/component/dsl.ex` | B | Component Spark DSL. Registers layer-4 transformers in pipeline. |
| `lib/lavash/component/runtime.ex` | B+S+R+O | Mirror of `LiveView.Runtime` for `Phoenix.LiveComponent`. Same multi-layer character. |
| `lib/lavash/component/compiler.ex` | O | `build_client_state` for components; reads JS deps from `__lavash_js_deps__`. |
| `lib/lavash/component/compiler_helpers.ex` | O | Colocated-JS target-dir resolution; `to_js` helpers. |
| `lib/lavash/component/helpers.ex` | O | `optimistic_state/2` for components; component state hydration via connect_params. |
| `lib/lavash/component/js_generator.ex` | O | HEEx node → JS template literal for subtree derives. |
| `lib/lavash/component/optimistic_wrapper.ex` | O | Wraps render output in a `LavashOptimistic` hook root div. |
| `lib/lavash/component/render_import.ex` | B | Re-exports `template/1`, `template_loading/1` for the component DSL. |
| `lib/lavash/component/state.ex` | B/S | Component state-binding struct. |
| `lib/lavash/component/calculate.ex` | R | Component `calculate` entity. Carries an `optimistic: true` default — layer-3 entity with a layer-4 field. |
| `lib/lavash/component/optimistic_action.ex` | O | Optimistic action entity. |
| `lib/lavash/component/prop.ex` | B | Component prop entity. |
| `lib/lavash/component/transformers/tokenize_template.ex` | B | Layer 1 of the template pipeline. |
| `lib/lavash/component/transformers/analyze_template.ex` | B+O | Extracts subtree derives + attr derives (both layer-4 concepts) AND phx-event refs / assign refs (layer-1 validation). Mixed-layer transformer — call this out. |
| `lib/lavash/component/transformers/compile_component.ex` | B | Final compile; generates `render/1`, `update/2`, `handle_event/2`. |

### Actions

| File | Layer | Notes |
| --- | --- | --- |
| `lib/lavash/action/runtime.ex` | B+R | Shared action execution: `apply_sets`, `apply_runs`, `apply_effects`, `coerce_value`. Calls `Lavash.Rx.Cache.compile_rx` to eval `set :foo, rx(...)`. |
| `lib/lavash/actions/action.ex` | B | The `action` entity. |
| `lib/lavash/actions/effect.ex` | B | `effect` op. |
| `lib/lavash/actions/flash.ex` | B | `flash` op. |
| `lib/lavash/actions/invoke.ex` | B | `invoke` (call child action). |
| `lib/lavash/actions/map_by.ex` | B/O | `map_by` op — keyed array mutation. Has optimistic JS but the entity itself is just a struct. |
| `lib/lavash/actions/navigate.ex` | B | |
| `lib/lavash/actions/push_event.ex` | B | |
| `lib/lavash/actions/push_patch.ex` | B | |
| `lib/lavash/actions/redirect.ex` | B | |
| `lib/lavash/actions/run.ex` | B | |
| `lib/lavash/actions/set.ex` | B+R | `set` op; value is an `rx()`. |
| `lib/lavash/actions/submit.ex` | B | |

### Lifecycle blocks

| File | Layer | Notes |
| --- | --- | --- |
| `lib/lavash/lifecycle/async_macro.ex` | B | `async :name do ... end`. |
| `lib/lavash/lifecycle/async_runtime.ex` | B+R | `fire`/`start_async`; calls `Reactive.recompute` after async completion. |
| `lib/lavash/lifecycle/messages_macro.ex` | B | `messages do message ... end end`. |
| `lib/lavash/lifecycle/mount_macro.ex` | B | `mount do ... end`. |
| `lib/lavash/lifecycle/on_mount_import.ex` | B | Re-exports `Phoenix.LiveView.on_mount/1`. |
| `lib/lavash/lifecycle/runtime.ex` | B+R | Lifecycle block execution; mark dirty, recompute, project. |

### Forms

| File | Layer | Notes |
| --- | --- | --- |
| `lib/lavash/form.ex` | B | `Lavash.Form` wrapper around Ash.Changeset. |
| `lib/lavash/form/section.ex` | B | `form` DSL entity. |
| `lib/lavash/form/step.ex` | B | Step-form variant. |
| `lib/lavash/form/runtime.ex` | B | Shared form runtime (extract resource/changeset, broadcast). |
| `lib/lavash/form/constraint_transpiler.ex` | O | Ash constraints → rx() for client validation. |
| `lib/lavash/form/validation_transpiler.ex` | O | Ash validations → client-side checks. |
| `lib/lavash/form/validation_js.ex` | O | JS generation for field validation. |

### Templates

| File | Layer | Notes |
| --- | --- | --- |
| `lib/lavash/template.ex` | B | Parses HEEx into `{:element, ...}` tree for analysis. |
| `lib/lavash/template/ast_transformer.ex` | B | Injects `__lavash_client_bindings__` into `.lavash_component` calls. |
| `lib/lavash/template/compiled.ex` | B | Compiled template struct (source-preserving). |
| `lib/lavash/template/render_macro.ex` | B | `template do ~H"..." end` / `template_loading do` macros. |
| `lib/lavash/template/token_transformer.ex` | B+O | The big mixed-layer transformer. Auto-injects `data-lavash-display` spans for bare `{@field}` (layer 4), wraps for visibility/enabled (layer 4), AND does layer-1-shape work (binding chain propagation). |

### Transformers (cross-cutting)

| File | Layer | Notes |
| --- | --- | --- |
| `lib/lavash/transformers/expand_fields.ex` | B+O | Expands DSL entities to field specs. Sets `optimistic: true` on many synthesized fields — layer-4 awareness embedded in layer-1 expansion. |
| `lib/lavash/transformers/validate_dsl.ex` | B | Cross-entity reference validation. |
| `lib/lavash/transformers/validate_template.ex` | B+O | Template-level event ref / assign ref validation. Knows about `setter_field?` (optimistic awareness). |

### Spark-Heex spike

| File | Layer | Notes |
| --- | --- | --- |
| `lib/lavash/spark_heex.ex` | B | Experimental: template-as-DSL-entity. |
| `lib/lavash/spark_heex/dsl.ex` | B | |
| `lib/lavash/spark_heex/template_macro.ex` | B | |
| `lib/lavash/spark_heex/transformers/compile_template.ex` | B | |
| `lib/lavash/spark_heex/transformers/ingest_template.ex` | B | |
| `lib/lavash/spark_heex/transformers/validate_action_params.ex` | B | |
| `lib/lavash/spark_heex/transformers/validate_events.ex` | B | |
| `lib/lavash/spark_heex/transformers/validate_template.ex` | B | |

### Derived entities

| File | Layer | Notes |
| --- | --- | --- |
| `lib/lavash/derived/field.ex` | R | `%Lavash.Derived.Field{}` — runtime derive struct with `optimistic`, `async`, compute fn. |
| `lib/lavash/derived/form.ex` | B | Form derive. |

### Overlays

| File | Layer | Notes |
| --- | --- | --- |
| `lib/lavash/overlay.ex` | O | Namespace + docs. |
| `lib/lavash/overlay/render_generator.ex` | B | Behaviour for overlay render generators. |
| `lib/lavash/overlay/modal.ex` | O | Modal plugin facade. |
| `lib/lavash/overlay/modal/dsl.ex` | B+O | Spark extension for modals. The DSL surface is layer-1-shaped but the open-field is always `animated: true`. |
| `lib/lavash/overlay/modal/render.ex` | B | `render` / `render_loading` structs. |
| `lib/lavash/overlay/modal/render_generator.ex` | O | Generates `render/1` with `data-lavash-*` chrome. |
| `lib/lavash/overlay/modal/helpers.ex` | B+O | Modal chrome components (backdrop, escape). |
| `lib/lavash/overlay/modal/transformers/inject_state.ex` | O | Injects animated `open_field` + `:close` / `:noop` actions. |
| `lib/lavash/overlay/modal/transformers/generate_render.ex` | B | Wires render generator into compile. |
| `lib/lavash/overlay/flyover/dsl.ex` | B+O | Same as modal. |
| `lib/lavash/overlay/flyover/render.ex` | B | |
| `lib/lavash/overlay/flyover/render_generator.ex` | O | |
| `lib/lavash/overlay/flyover/helpers.ex` | B+O | |
| `lib/lavash/overlay/flyover/transformers/inject_state.ex` | O | |
| `lib/lavash/overlay/flyover/transformers/generate_render.ex` | B | |

### Bundled components

| File | Layer | Notes |
| --- | --- | --- |
| `lib/lavash/chip_set.ex` | O | Self-contained optimistic chip-set component. |
| `lib/lavash/toggle_chip.ex` | O | |
| `lib/lavash/components/synced_toggle.ex` | O | |
| `lib/lavash/components/tag_editor.ex` | O | |
| `lib/lavash/components/components_macro.ex` | B | Block-structured DSL for function components. |

---

## Client Module Inventory (JS)

| File | Layer | Notes |
| --- | --- | --- |
| `priv/static/index.js` | O | Public exports (`lavash`, `defaultConcerns`, `getHooks`, `getState`, primitives). |
| `priv/static/lavash.js` | S+O | Owns the global `lavashState` object AND the `phx:_lavash_sync` listener (layer 2) — and exports `SyncedVar` / `OverlayAnimator` (layer 4). Two transports in one file. |
| `priv/static/url_sync.js` | S | URL sync via `history.replaceState`. Pure layer 2. |
| `priv/static/synced_var.js` | O | `SyncedVar` + `SyncedVarStore`. The optimistic substrate (version/confirmedVersion/isPending/closeProtection). |
| `priv/static/reactive_store.js` | O | Unified reactive state: graph + version tracking + SyncedVar composition. |
| `priv/static/merge_walker.js` | O | Visitor-based merge of server payload into hook state, respecting pending paths. |
| `priv/static/graph.js` | R | Pure graph algorithms (BFS, topo, parseGraph). Mirror of `Lavash.Graph`. Pure layer 3. |
| `priv/static/overlay_animator.js` | O | `SyncedVar` delegate for modal/flyover open/close animations. |
| `priv/static/pipeline.js` | O | Decorator factory; the `lavash()` runtime. |
| `priv/static/pipeline_core.js` | O | Core init / observe / merge / recompute / render cycle. Owns `hook.store` (SyncedVarStore). |
| `priv/static/PIPELINE.md` | O | Architecture doc for the pipeline. |
| `priv/static/package.json` | B | Package metadata. |

### Concerns

| File | Layer | Notes |
| --- | --- | --- |
| `priv/static/concerns/optimistic_actions.js` | O | Lifecycle orchestrator for click-interception of optimistic `phx-click`. |
| `priv/static/concerns/optimistic_action_helpers.js` | O | Click classification + state-delta application. |
| `priv/static/concerns/bindings.js` | O | Parent↔child state propagation lifecycle. |
| `priv/static/concerns/binding_helpers.js` | O | `refreshFromParent`/`propagateBoundFieldsToParent` (operate against `SyncedVarStore`). |
| `priv/static/concerns/forms.js` | O | Forms lifecycle (touched-field tracking, server validation debounce, modal-open clearing). |
| `priv/static/concerns/form_handler.js` | O | Form input listeners, blur/touched, formatting. |
| `priv/static/concerns/overlays.js` | O | Modal/flyover phase machine lifecycle. |
| `priv/static/concerns/overlay_manager.js` | O | SyncedVar + OverlayAnimator wiring. |
| `priv/static/concerns/dom_updater.js` | O | Renders state to `data-lavash-*` annotated DOM. |
| `priv/static/concerns/global_dom_callback.js` | O | `morphdom`'s `onBeforeElUpdated` interception (input preservation, display preservation, overlay preservation). |
| `priv/static/concerns/function_loader.js` | O | Loads colocated JS per module from `window.Lavash.optimistic[...]`. |
| `priv/static/concerns/utils.js` | O | `setStateAtPath`, `getStateAtPath`, isInsideChildHook, etc. |

### Decorators

| File | Layer | Notes |
| --- | --- | --- |
| `priv/static/decorators/compose.js` | B | Generic decorator composition. Layer-1 substrate; not optimism-specific. |
| `priv/static/decorators/index.js` | B+O | Bundles default + opt-in decorators. |
| `priv/static/decorators/log_lifecycle.js` | B | Dev-only logger. |

---

## Dependency Diagram

```
                  ┌──────────────────────────────────────┐
                  │         Layer 4: optimism            │
                  │  Optimistic.*, SyncedVar, pipeline,  │
                  │  optimistic_actions, merge_walker,   │
                  │  data-lavash-*, JS transpiler,       │
                  │  phase machine, OverlayAnimator      │
                  └──────────────────────────────────────┘
                                  │ depends on
                                  v
                  ┌──────────────────────────────────────┐
                  │         Layer 3: rx                  │
                  │  Reactive, Rx, Rx.Graph, Rx.Cache,   │
                  │  Dsl.Graph, defgraph, defrx          │
                  └──────────────────────────────────────┘
                                  │ depends on
                                  v
                  ┌──────────────────────────────────────┐
                  │         Layer 2: state               │
                  │  put_state, hydrate_*, Type,         │
                  │  State.Field+subtypes, lavashState,  │
                  │  phx:_lavash_sync, url_sync.js       │
                  └──────────────────────────────────────┘
                                  │ depends on
                                  v
                  ┌──────────────────────────────────────┐
                  │         Layer 1: base                │
                  │  Dsl, transformers, TagEngine,       │
                  │  actions, lifecycle, template macros,│
                  │  Spark.Heex spike, forms (Ash)       │
                  └──────────────────────────────────────┘
                                  │ depends on
                                  v
                  ┌──────────────────────────────────────┐
                  │  Phoenix.LiveView / Spark / Ash      │
                  └──────────────────────────────────────┘
```

The intent is "each layer depends only on the layer below it (and on outside
libraries)." Violations and back-edges are listed below.

Concrete edges that EXIST today (compile or runtime):

  * **L1 → L4**: `lib/lavash/dsl.ex` and `lib/lavash/component/dsl.ex` register
    layer-4 transformers in the pipeline. **Violation, by design** —
    a pure layer-1 DSL would not know about `ExtractColocatedJs`.
  * **L1 → L4**: `lib/lavash/dsl/common_entities.ex` declares `optimistic:` and
    `animated:` in the shared schema. **Violation** — these options should
    live in a layer-4 extension of the schema.
  * **L2 → L4**: `lib/lavash/socket.ex` defines `optimistic_version` /
    `bump_optimistic_version`. **Violation** — the version counter is a
    layer-4 reconciliation concern; it shouldn't sit alongside layer-2
    dirty-tracking.
  * **L1 → L4**: `lib/lavash/template/token_transformer.ex` auto-injects
    `data-lavash-display` spans. **Violation** — a pure layer-1 token
    transformer wouldn't emit layer-4 markers.
  * **L4 → L3**: `lib/lavash/optimistic/transformers/extract_colocated_js.ex`
    reads `Lavash.Rx.Transpiler`. **OK** — correct direction.
  * **L4 → L2**: `lavash.js` writes to `lavashState` and listens for
    `phx:_lavash_sync`. **OK** — uses layer 2 as intended.

---

## Back-edges (lower layer reaches up, or sideways into a higher layer)

### Server back-edges

#### From base into optimism

- **`lib/lavash/dsl.ex:523-530`** — `Lavash.Dsl` lists
  `Lavash.Optimistic.Transformers.ExpandAnimatedStates`,
  `Lavash.Optimistic.Transformers.ExpandDefrx`,
  `Lavash.Optimistic.Transformers.ExtractColocatedJs` directly in its
  `transformers:` list. **Verdict:** unavoidable today because Spark
  extensions are a single registration point, but it does mean you can't `use
  Lavash.LiveView` without paying the optimistic-JS-generation cost. A layer-2-
  only `use Lavash.LiveView.NoOptimism` does not exist.
- **`lib/lavash/component/dsl.ex:282-288`** — same pattern for the component
  DSL. **Verdict:** same as above.
- **`lib/lavash/dsl/common_entities.ex:35,40,357`** — `optimistic:` and
  `animated:` options live in the shared schema. **Verdict:** violation. A
  pure layer-1 entity would not declare these. Could move to a layer-4 schema
  fragment merged in by an optional extension.
- **`lib/lavash/live_view.ex:55,59`** — `__lavash_optimistic_actions__`
  attribute + `import Lavash.Optimistic.Macros, only: [optimistic_action: 3]`.
  **Verdict:** violation. The base layer's `use` macro pulls in layer-4
  macros.
- **`lib/lavash/live_view/runtime.ex:30-100`** — `wrap_render/3` is the
  layer-4 injection point but lives in the layer-1 runtime. Calls
  `Lavash.LiveView.Helpers.optimistic_state`, `Lavash.JSON.encode!`,
  `LSocket.optimistic_version`. **Verdict:** violation by integration —
  defensible because mount/render is the natural single seam, but it means the
  base runtime has hard-coded knowledge of the optimistic transport.
- **`lib/lavash/live_view/runtime.ex:908`** — `push_event("_lavash_sync", ...)`.
  Layer-1 runtime pushing the layer-2 sync transport. **Verdict:** OK — layer 2
  consumed from above is fine.
- **`lib/lavash/live_view/transformers/compile_live_view.ex:330-332`** —
  registers `@after_compile {Lavash.Reactive, :erase_graph}` (layer 3),
  `{Lavash.Rx.Cache, :erase}` (layer 3), `{Lavash.Dsl.Graph, :erase}`
  (layer 3). **Verdict:** OK direction.
- **`lib/lavash/live_view/transformers/compile_live_view.ex:378-379,422-423`** —
  generates `__lavash_optimistic_actions__/0` and weaves
  `optimistic_actions` into the declared actions. **Verdict:** violation —
  layer-1 compiler synthesises layer-4 hooks.
- **`lib/lavash/component/transformers/compile_component.ex:85-86,368-398`** —
  same as above for components: `@after_compile` hooks plus
  `optimistic_actions_map` / `attr_derives` baked into the component metadata.
  **Verdict:** violation by integration.
- **`lib/lavash/component/transformers/analyze_template.ex`** (entire file) —
  one transformer extracts BOTH layer-1-shaped data (assign refs, phx-event
  refs eventually used by `ValidateTemplate`) AND layer-4 data (subtree
  derives, attr derives, `data-lavash-html` injection). **Verdict:**
  violation. This transformer does too many jobs; the optimism-shaped jobs
  (subtree derive extraction, attr derive extraction, `data-lavash-html`
  injection) could move into the `ExtractColocatedJs` transformer or a
  dedicated layer-4 analyzer that runs after a layer-1 analyzer.
- **`lib/lavash/template/token_transformer.ex:122-130,247,665-667`** —
  bare-`{@field}` auto-wrapping in `<span data-lavash-display>`,
  `attr_derives` consumption, "declared but not optimistic" warning.
  **Verdict:** violation. A layer-1 token transformer is auto-emitting
  layer-4 DOM attributes.
- **`lib/lavash/transformers/expand_fields.ex:216,266,289,299,363,540,578,642,659,684`** —
  synthesised fields (chip set, toggle chip, form fields, etc.) hard-code
  `optimistic: true`. **Verdict:** violation. Field expansion at layer 1
  shouldn't know that synthesized fields are optimistic. The
  optimism-default could be applied by a layer-4 pass over the expanded
  fields.
- **`lib/lavash/transformers/validate_template.ex:128-130`** — `setter_field?`
  checks `:optimistic` and `:animated`. **Verdict:** violation. Validation at
  layer 1 reads layer-4 flags.
- **`lib/lavash/live_view/components.ex`** (whole module) — form components
  use `data-lavash-*` attributes. **Verdict:** violation. Layer-1 component
  bundle hard-codes layer-4 DOM contract.
- **`lib/lavash/overlay/modal/transformers/inject_state.ex:100`** /
  **`lib/lavash/overlay/flyover/transformers/inject_state.ex:100`** — modal
  / flyover state inject `optimistic: true`. **Verdict:** by design — modals
  are always optimistic — but the modal/flyover DSLs are mixed-layer
  features (a non-optimistic modal makes no sense, so this is largely fine).
- **`lib/lavash/derived/field.ex:16`** — `%Lavash.Derived.Field{}` carries
  `optimistic: false` field. **Verdict:** OK — schema field is benign; the
  default is "no, not optimistic."
- **`lib/lavash/component/calculate.ex:32`** — `defstruct optimistic: true`.
  **Verdict:** violation. Layer-3 entity defaults to layer-4 behaviour.

#### From state into optimism

- **`lib/lavash/state/state_field.ex:38,49-53`** — struct fields `:optimistic`
  and `:animated`; `optimistic?/1` helper. **Verdict:** violation. Layer-2
  state field struct knows about layer-4 concepts. Mitigation: keep the
  fields but make them opaque metadata that layer 4 reads.
- **`lib/lavash/socket.ex:31,88,212-213`** — `optimistic_version` field +
  `optimistic_version/1` + `bump_optimistic_version/1`. **Verdict:**
  violation. The version counter is layer-4 state being kept in the layer-2
  socket struct.
- **`lib/lavash/assigns.ex:15`** — projects `__lavash_parent_version__` into
  assigns. **Verdict:** violation. Layer-2 assigns projection knows about the
  optimistic-version reconciliation.

#### From rx into optimism

- **`lib/lavash/component/calculate.ex:32`** — listed above; `optimistic: true`
  default on a layer-3 entity.
- **`lib/lavash/rx/transpiler.ex`** — lives under `rx/` but the AST-to-JS
  transpilation is pure layer 4. **Verdict:** misfiled; should arguably live
  under `lib/lavash/optimistic/transpiler.ex`. Minor — purely cosmetic
  rename.
- **`lib/lavash/reactive/graph_macro.ex:138`** — calls
  `Lavash.Rx.Transpiler.to_js`. **Verdict:** by design (the macro is
  explicitly dual-layer: it builds the graph AND emits client JS). Could be
  factored into a layer-3 `defgraph` and a layer-4 wrapper.

### Client back-edges

- **`priv/static/lavash.js:35-50`** — `lavashState` global lives in the same
  file as the `SyncedVar` re-export. **Verdict:** violation by file
  organisation. The layer-2 `lavashState` should live in a `state_sync.js`
  alongside `url_sync.js`; the layer-4 primitives should be exported from a
  separate entry. Today they coexist because the file is the global
  side-effects file. (See "JS-split investigation" — this finding is already
  established.)
- **`priv/static/index.js`** — exports both `getState` (layer 2) and
  `SyncedVar` (layer 4) from the same public entry. **Verdict:** OK
  pragmatically (one library), but if you split, the public surface would
  split too.
- **`priv/static/concerns/global_dom_callback.js:36,91`** — reads
  `hook.store.isPending(...)`. **Verdict:** OK — the concern operates on the
  layer-4 store, which is its job.
- **`priv/static/concerns/bindings.js:62-96`** — calls
  `syncedVar.setOptimistic`, branches on animated/non-animated. **Verdict:**
  bindings ride on the optimistic store today; this is the gray area
  identified in the prompt. The concern uses layer-4 SyncedVar primarily for
  bookkeeping (so the server echo doesn't clobber the binding-propagated
  value mid-flight). It could in principle work against a non-optimistic
  store; today it's tangled.
- **`priv/static/concerns/forms.js`** / **`priv/static/concerns/form_handler.js`** —
  same as bindings: use `SyncedVar` for input-preservation. **Verdict:** gray
  area; same as above.

---

## Cleanup Punchlist

Ranked by impact-to-clarity. **Impact** key: **L2-only** = would unblock
consuming layer 2 (or layer 2 + 3) without the optimistic JS bundle / DSL
surface; **nice** = would make the layering legible without enabling new
consumption modes; **cosmetic** = pure code-organisation win.

1. **(S, L2-only)** Move `optimistic_version` / `bump_optimistic_version` out
   of `Lavash.Socket` into a layer-4 sidecar (e.g.
   `Lavash.Optimistic.Version`). Likewise move
   `__lavash_parent_version__` projection out of `Lavash.Assigns`. This is
   the cleanest path to "consume layer 2 without pulling in optimism" since
   `Socket` is currently irreducibly mixed.

2. **(M, L2-only)** Split `priv/static/lavash.js` into:
   - `state_sync.js` — owns `lavashState`, `_lavash_sync` listener,
     `getState()`.
   - `lavash.js` — public optimistic entry only.
   Today these live in one file purely because the global side-effects
   needed a home. Pulls layer-2-only consumers out of layer-4 dependency.

3. **(M, L2-only)** Extract `optimistic:` / `animated:` schema fragments out
   of `Lavash.Dsl.CommonEntities` and into a layer-4 schema-extension
   protocol. Today the base DSL surface explicitly mentions them; a
   `use Lavash.LiveView.Base` would still ship with these schema keys in
   tow.

4. **(M, nice)** Move the layer-4 jobs out of
   `Lavash.Component.Transformers.AnalyzeTemplate`. Subtree-derive
   extraction, attr-derive extraction, and `data-lavash-html` injection
   should live in a transformer registered by the optimism extension.
   Phx-event / assign-ref collection can stay (it's layer-1 validation
   data).

5. **(M, nice)** Move bare-`{@field}` auto-wrapping in `<span
   data-lavash-display>` out of `Lavash.Template.TokenTransformer` and into
   a layer-4 token transformer. The behaviour-based registry is already
   there; this is purely a relocation.

6. **(S, nice)** Rename `Lavash.Rx.Transpiler` to
   `Lavash.Optimistic.Transpiler`. Pure relocation — the module's job is
   layer 4. Watch out for `Lavash.Rx.Transpiler.js_field_access` /
   `js_field_key` helper calls scattered through the codebase (extract
   colocated, validation_js, etc.).

7. **(M, nice)** Decouple `Forms` and `Bindings` concerns from `SyncedVar`.
   Today they use `setOptimistic` for bookkeeping; a layer-2-shaped store
   interface (set/get/observe) would let them work against either a
   non-optimistic or optimistic backing. *Needs investigation — the
   bookkeeping is real (server echoes mid-typing) and may require
   reproducing meaningful chunks of SyncedVar.*

8. **(M, L2-only)** Audit `Lavash.LiveView.Runtime.wrap_render/3`. The single
   render-wrapper that injects the `LavashOptimistic` hook means
   `Lavash.LiveView` always emits the layer-4 hook. If `optimistic_fields ==
   []`, today we already skip the wrapper — good. But the call site in
   `compile_live_view.ex:638-649` is layer-1. Could move to a layer-4
   transformer that registers itself as a render-wrapping decorator on the
   compiled LiveView.

9. **(S, nice)** Move `optimistic: true` defaults out of
   `Lavash.Transformers.ExpandFields` synthesised entries (chip set, toggle
   chip, form fields). Have `ExpandFields` emit "neutral" specs and let a
   later layer-4 transformer mark them optimistic.

10. **(L, L2-only)** Provide `Lavash.LiveView.Base` / `Lavash.Component.Base`
    that registers ONLY layer-1 transformers, so users who want the DSL
    without optimism (or without rx) can opt in. This is the natural
    end-state of (1)–(5) but is large because it touches every
    transformer's pipeline registration.

11. **(S, cosmetic)** `Lavash.Component.Calculate` defaults `optimistic:
    true`. Flip the default to `false` and have the optimistic extension
    flip it back on registration. Cosmetic but signals layering intent.

12. **(M, nice)** `lib/lavash/live_view/components.ex` (form components with
    daisyUI classes + `data-lavash-*`) is layer-4 living under
    `live_view/`. Move to `lib/lavash/optimistic/components.ex` (or split
    daisyUI styling into a separate optional module).

13. **(S, cosmetic)** Spark-Heex spike (`lib/lavash/spark_heex/*`) is
    exploratory layer-1 work. Either elevate to first-class (and integrate
    with the main `Lavash.Dsl` pipeline) or move under `examples/` /
    `priv/spike/`. Nothing else imports it.

14. **(M, nice)** `lib/lavash/optimistic/transformers/expand_animated_states.ex`
    emits state fields with `optimistic: true` directly. Once (3) is done,
    this should use whatever the layer-4 schema-extension protocol becomes.

15. **(S, cosmetic)** `lib/lavash/component/transformers/compile_component.ex`
    duplicates a lot of plumbing with
    `lib/lavash/live_view/transformers/compile_live_view.ex`. Not a
    layering violation per se, but shared base-layer plumbing could live in
    a `Lavash.CompileShared` module.

---

## Closing notes

- Layer 4 dominates the line count. The optimistic substrate (server JS
  generation + client pipeline + DOM annotations) is the largest single
  concern in the repo.
- Layers 2 and 3 are reasonably clean on their own — `Lavash.Reactive` /
  `Lavash.LiveView.Explicit` already demonstrate that you can consume layer 3
  without layer 4, and `lib/lavash/state.ex` is genuinely layer-2-only.
- The biggest leakage point is at the **DSL entity** level: `optimistic:` and
  `animated:` keys live in the shared base schema, and several layer-1/2/3
  structs carry layer-4 fields directly. Fixing this (items 1, 3, 11) is the
  most impactful clarity win.
- The biggest leakage point on the **JS side** is the conflation of the
  `lavashState` global with `SyncedVar` exports in `lavash.js`. Splitting the
  files (item 2) would let a layer-2-only consumer drop the optimistic
  bundle entirely.
