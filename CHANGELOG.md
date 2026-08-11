# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Sync-state DOM annotations** (#72). Optimistic predictions are now
  distinguishable from confirmed state via attributes derived from
  SyncedVar state on every render: `data-lavash-syncing` +
  `aria-busy="true"` on the hook root while any of the hook's own vars
  is unresolved (pending optimistic set OR provisional append/upsert
  seed); `data-lavash-pending` on elements bound to an unresolved field
  (directly or through the derive graph); `data-lavash-provisional` on
  predicted rows inside projected subtrees — opt in by rendering
  `data-lavash-id={row.id}` on the row template. Provisional seeds
  resolve on the same-event re-read; `hook.hasUnresolved()` exposes the
  predicate (also what #63's navigation guard needs). No default
  styling — a page indicator can watch
  `body:has([data-lavash-syncing])`, and the recommended CSS delays the
  visible affordance ~250ms so fast round-trips never flash it (see
  the demo's header sync dot + dimmed provisional cart rows).

### Fixed

- **Sync indicator no longer sticks on after debounced typing.**
  `version` counts client mutations while the anti-bounce incremental
  confirm counts server patches, so typing N characters into a bound
  input (one debounced push) left the var version-pending forever and
  `data-lavash-syncing` stuck on. `isUnresolved` now means: pending AND
  the server's last word differs from the on-screen value — merge-level
  bounce protection is untouched.

- **Bound fields no longer stay pending forever after parent→child
  refresh.** `refreshFromParent` marked the mirrored value as an
  optimistic set — but no confirming push ever comes for a mirror, so
  the var (and now the `data-lavash-syncing` indicator) stayed
  unresolved indefinitely; it also compared by identity, re-marking
  array/object values changed on every parent render. Plain vars now
  `seed()` (confirmed, non-pending) under a `deepEqual` guard; animated
  vars keep the phase-machine path (their pending state resolves on the
  next patch).

### Changed

- **BREAKING: bindable component fields must be declared `from: :bound`**
  (#87). A component's bindable surface is now explicit: only
  `from: :bound` state fields may be targeted by
  `bind={[child: :parent]}`. When bound, the parent field owns source,
  persistence, and seeding; unbound, the field falls back to ephemeral
  behavior with its own default. Binding a prop, an
  `:ephemeral`/`:socket` field, or an unknown name raises — at compile
  time when `module=`/`bind=` are literals (`Spark.Error.DslError`), at
  first mount otherwise (`ArgumentError`). The parent side is also
  validated at compile time: it must not be a calculation, concrete
  types must agree, and binding an optimistic child field to a
  non-client-visible parent field is an error. Overlay `open` fields
  (modal/flyover DSL) and the bundled components (TagEditor, ChipSet,
  ToggleChip, SyncedToggle) are already migrated — user components with
  bindable fields need `from: :ephemeral` → `from: :bound`.

## [0.4.0-rc.5] — 2026-06-08

Fixes the optimistic-template transpiler, which emitted invalid or
silently-broken client JS for several valid Elixir constructs — failures
that only surfaced at prod `esbuild`, never at `mix compile`/test. The
analysis now decides per expression whether it actually needs client
transpilation, and raises a clear compile-time error when an
optimistic-dependent expression can't be transpiled.

### Fixed

- **`?`-suffixed keys on nested access** (`@matrix.declared?`,
  `r.spec_home?`) emitted `obj.declared?` — invalid JS (esbuild
  "Unexpected ?"). They now route through `js_field_access/2` and emit
  quoted bracket keys: `obj["declared?"]`. (Top-level `@`-refs already
  did this; nested/loop-variable access bypassed it.)

- **Empty-list comparison** `x == []` / `x != []` emitted `x === []` /
  `x !== []`, which in JS compares against a fresh array literal (always
  false / always true). Now emits `.length === 0` / `.length > 0`.

### Added

- **Loop-aware optimistic analysis.** `:for={x <- src}` now binds `x` as
  optimistic-derived only when `src` is optimistic. A loop variable over a
  static list is server-rendered (no client transpilation, no error); over
  an optimistic list it drives a client re-render. `build_optimistic_names`
  now also includes optimistic `state` fields (previously only
  calculations/forms/actions), so `:if`/`:for`/`{...}` over optimistic
  state transpile as expected.

- **Compile-time error for untranspilable optimistic expressions.** When an
  expression depends on optimistic state but has no JS equivalent (a local
  helper call, `fn`, an unsupported comprehension), lavash now raises a
  `Spark.Error.DslError` at `mix compile` naming the source line and the
  offending construct, with remedies (move it to a `calculate`/`defrx`, or
  drop the optimistic dependency to render it server-side). Previously this
  emitted invalid JS that broke prod esbuild, or a placeholder that
  silently dropped that part of the DOM. `defrx` helpers are expanded
  before validation, so they are not flagged.

## [0.4.0-rc.4] — 2026-06-06

Templates are now declared with a single shape: `template do ~H"..." end`
(and `template_loading do ~H"..." end` for overlay loading states). The
legacy `render fn assigns -> ~L"..." end` / `render_loading fn` variant
and the `~L` sigil are removed. This release also lands several
compile-time validations that turn common typo-class bugs into build
errors.

### Removed

- **The `render fn assigns -> ~L"..." end` / `render_loading fn` variant
  and the `~L` sigil.** `template do ~H"..." end` is now the only way to
  declare a LiveView/Component template, and `template_loading do ~H"..."
  end` the only way to declare an overlay loading body. Internally the
  loading template now flows through the same token pipeline as the main
  render (previously it rode an escaped-fn path that depended on the `~L`
  sigil). The dead `Lavash.Sigil`, `Lavash.Template.Compiled`,
  `Lavash.Render`, `Lavash.Component.Render`, and `Lavash.Component.Template`
  modules were deleted.

  **Migration:** replace

      render fn assigns ->
        ~L\"\"\"
        <div>{@count}</div>
        \"\"\"
      end

  with

      template do
        ~H\"\"\"
        <div>{@count}</div>
        \"\"\"
      end

  and `render_loading fn assigns -> ~L"..." end` with
  `template_loading do ~H"..." end`. Inside `components do component ...`
  blocks, replace the `render fn assigns -> ~H"..." end` body with
  `template do ~H"..." end`.

### Added

- **Compile-time validation of `phx-click` / `phx-submit` / `phx-change`
  references.** Static-string event values on plain HTML tags are
  cross-checked against the module's declared actions (and
  auto-generated `set_<name>` setters from `state ..., setter: true`).
  A typo'd `phx-click="incremnt"` now raises a `Spark.Error.DslError`
  at compile time with a Levenshtein-based suggestion, instead of
  surfacing as a silent no-op in the browser. Dynamic expressions
  like `phx-click={JS.dispatch(...)}` and events on component nodes
  are skipped — the validator only checks references it can
  statically resolve.

- **Compile-time validation of `phx-value-*` attribute names against
  action `params` lists.** `<button phx-click="bump_by"
  phx-value-amout="5">` now raises at compile time if `:bump_by`
  declared `params [:amount]`, with a suggestion to `phx-value-amount`.
  Catches typos whose runtime symptom was a silently-nil param —
  often crashing later inside `String.to_integer(nil)`. Auto-generated
  `set_<name>` setters accept only `phx-value-value`.

- **Compile-time validation of `@name` assign references in HEEx.**
  Every `@name` in a template (`{@field}`, `:if={@open}`,
  `class={@theme}`, `<%= @count %>`, etc.) must resolve to a
  declared `state`, `prop`, `slot`, `calculate`, `async`, or `form`
  on the module — or to a Phoenix-injected assign (`@flash`,
  `@socket`, `@live_action`, `@uploads`, `@streams`, `@id`,
  `@myself`, `@inner_block`). Typos like `{@flsh[:info]}` or
  `:if={@opn}` now raise a `Spark.Error.DslError` at compile time
  with a Levenshtein-based suggestion. `?`-suffix field names
  (e.g. `state :is_admin?, :boolean`) are matched correctly.

  **Migration note:** on_mount hooks that inject assigns previously
  worked implicitly — the assigns landed on `socket.assigns` and
  were available in templates without lavash knowing. With this
  validation in place, hook-injected assigns must be declared
  via `state :name, :type, from: :assigns, assigns_key: :name`
  to be referenced in HEEx. This makes the source of every
  template assign explicit and gives the field a place in the
  reactive graph.

## [0.4.0-rc.3] — 2026-05-25

The optimistic JS pipeline was broken in rc.1/rc.2 — lavash's
client-side optimistic patches never reached the browser. The
end-state-only browser tests masked it because server reconciliation
arrives within the 5s default assertion timeout, indistinguishable
from a working optimistic patch. This release fixes the pipeline,
restores client-side optimistic behaviour, and reworks the test
infrastructure so silent regressions of this class can't slip
through again.

### Fixed

- **Colocated JS extraction silently deleted.** Lavash's
  `ExtractColocatedJs` transformer was writing per-module
  optimistic JS via raw `File.write!` and returning a 2-tuple from
  `__phoenix_macro_components__/0`. Phoenix's
  `ColocatedAssets.compile/0` pass expects `%Entry{}` structs;
  finding none, it considered lavash's files orphaned and deleted
  them on every compile. Net effect on rc.1/rc.2: optimistic action
  fns and `calculate :foo, rx(...)` JS never reached the browser.
  Every "optimistic" click was actually a server round-trip.

  Fix: use Phoenix.LiveView.ColocatedAssets.extract/5, which
  writes the file AND returns the proper `Entry`. The persisted
  Entry flows through `__phoenix_macro_components__/0`; Phoenix
  tracks it; file survives.

- **`<input type="checkbox" data-lavash-bind="...">` wrote the
  wrong value.** `form_handler.handleInput` unconditionally read
  `target.value`, which for a checkbox is the static `value=""`
  attribute regardless of checked-state. Ticking a checkbox with
  `value="true"` wrote the string `"true"` to optimistic state on
  both check AND uncheck — and downstream `data-lavash-enabled
  === true` strict checks (and any boolean-typed reactive graph)
  silently failed.

  Fix: read `target.checked` for checkbox, `target.selectedOptions`
  for `<select multiple>`, and skip change events on radios where
  `target.checked === false` (so the unchecked sibling doesn't
  overwrite the newly-selected radio's value).

- **`[head | tail]` cons-prepend produced `[undefined]` in JS.**
  Any `rx()` body using list-cons syntax (e.g.
  `set :items, rx([@name | @items])`) emitted `[undefined]` in the
  transpiled JS because the cons AST node fell through to the
  untranspilable fallback. At runtime, the array became `[null]`
  after JSON serialization.

  Fix: detect cons nodes inside list literals and emit JS spread.
  `[@name | @items]` becomes `[name, ...items]`; multi-head
  `[a, b | c]` becomes `[a, b, ...c]`.

- **Modal reopen during exit animation silently failed.** A user
  closing a modal and immediately reopening it before the 200ms
  exit animation completed left the modal closed. The SyncedVar's
  `_closeProtection` flag was being re-armed in
  `_serverSetAnimated` after `IdlePhase.onEnter` had cleared it,
  causing the server's eventual reopen diff to be rejected as
  "stale."

  Fix: clear `_closeProtection` in `IdlePhase.onEnter` (the close
  is fully done; future server values are fresh), and remove the
  redundant re-set in `_serverSetAnimated`. The
  setOptimistic+idle-clear pair already provides the bounce
  protection.

- **`?`-suffix field names produced invalid JS.** Elixir allows `?`
  in atom names (idiomatic for booleans like `:is_admin?`), but JS
  identifiers don't. The transpiler emitted
  `state.is_admin?` and `{is_admin?: ...}`, both `SyntaxError`s.

  Fix: new `Lavash.Rx.Transpiler.js_field_access/2` and
  `js_field_key/1` helpers wrap unsafe names with bracket access /
  string-key form. `state["is_admin?"]`, `{"is_admin?": ...}`.
  Applied across the transpiler, action set deltas, map_by
  transforms, calc emissions, attr/subtree derive emissions, and
  action method declarations.

### Added — test infrastructure

- **Phoenix.LiveView.ColocatedJS wired into the lavash test app.**
  `test/support/endpoint.ex` now serves the colocated manifest at
  `/assets/phoenix-colocated/lavash`; the test layout imports the
  `optimistic` export and assigns to `window.Lavash.optimistic` so
  the JS pipeline's `loadGeneratedFunctions` can dispatch by module
  name. Without this load, the e2e tests verified only server
  reconciliation arrival, not the optimistic phase.

- **Latency tests tightened to actually verify optimistic timing.**
  `test/integration/latency_test.exs` now uses
  `@moduletag wallabidi_timeout: 100` — under the 400ms latency
  simulator, assertions can only pass via the client-side patch.
  If the optimistic path silently breaks again (colocated JS
  pipeline regression, transpiler bug, hook init failure), these
  tests fail within 100ms instead of passing 800ms later via
  server reconciliation.

- **Regression test for the checkbox-bind value bug.**
  `test/integration/checkbox_bind_test.exs` asserts the bind writes
  the boolean `true` (not the string `"true"`) after a click. Uses
  `Wallabidi.Remote.Protocol.eval` to inspect `hook.state` directly.

## [0.4.0-rc.2] — 2026-05-25

### Added

- **`from: :assigns`** — a new state source that lifts a value an
  `on_mount` hook put on `socket.assigns` into lavash state. Closes
  the AshAuthentication integration gap: the on_mount assigns
  `:current_user`, and lavash can now expose it to `rx()` without a
  custom `mount/3` escape hatch.

  ```elixir
  on_mount {AshAuthentication.LiveView, :live_user_required}

  state :user, :map, from: :assigns, assigns_key: :current_user

  calculate :greeting, rx("Hello, " <> @user.name)
  ```

  One-way read: lavash mutations don't propagate back to
  `socket.assigns`. Missing assign falls back to `default:`.
  `assigns_key:` defaults to the field name. LV-only (not
  Lavash.Component — components receive parent data via props).

## [0.4.0-rc.1] — 2026-05-25

The 0.4 line starts here. Two big shifts since rc.5: lavash now has
DSL coverage for the LiveView callback surface (parity work against
vanilla LV), and the JS hook is replaced by a composable concern
pipeline that auto-decorates user hooks.

### Breaking

- **`LavashOptimistic` JS hook removed.** It was a monolithic Phoenix
  hook (~470 lines doing optimistic state, modal/flyover animation,
  form input tracking, parent↔child component bindings, click
  interception). Replaced by `lavash({ concerns: [...] })` — a
  decorator factory built around a concern pipeline.

  Migration in `app.js`:
  ```js
  // Before
  import { LavashOptimistic, SyncedVar, OverlayAnimator } from "lavash";
  window.Lavash = window.Lavash || {};
  window.Lavash.SyncedVar = SyncedVar;
  window.Lavash.OverlayAnimator = OverlayAnimator;
  const liveSocket = new LiveSocket("/live", Socket, {
    params: { _csrf_token: token },
    hooks: { LavashOptimistic }
  });

  // After
  import { lavash, defaultConcerns, getHooks, getState } from "lavash";
  const lavashDecorator = lavash({ concerns: defaultConcerns });
  const liveSocket = new LiveSocket("/live", Socket, {
    params: () => ({ _csrf_token: token, _lavash_state: getState() }),
    hooks: getHooks(lavashDecorator, MyAppHooks)
  });
  ```

  The `LavashOptimistic` *hook name* still exists in markup (the
  server runtime emits `phx-hook="LavashOptimistic"`); `getHooks()`
  registers the decorator under that name. User hooks passed to
  `getHooks` are auto-decorated — lavash activates only on elements
  carrying `data-lavash-state` (zero cost on user hooks elsewhere).

### Added — DSL capabilities

- **`messages do message :name do ... end end`** — declarative
  `handle_info` capability. Body is an op-sequence
  (`run`/`effect`/`set`/`fire`) drawn from the same vocabulary as
  action bodies. Replaces the escape hatch of custom
  `handle_info/2` for PubSub broadcasts, self-scheduled timers,
  monitor messages.

- **`components do component :name do ... end end`** — block-structured
  function-component DSL using `prop`/`slot`/`render fn`. Replaces
  the positional `attr`/`slot` macros from Phoenix.Component, which
  attach to the next-defined function (refactor-fragile). The block
  form makes the function-to-schema relationship explicit.

- **`async :foo do run fn assigns -> ... end end`** — declares a
  triggerable async task. Lands as
  `%Phoenix.LiveView.AsyncResult{}` on assigns. Routed through
  `Phoenix.LiveView.start_async/3` so `render_async/2` in tests sees
  it.

- **`fire :foo` op** — triggers an `async` declaration. Available
  inside action bodies, message bodies, and the new `mount do`
  block. One declaration, multiple trigger paths.

- **`mount do <ops> end`** — lifecycle block symmetric with
  `messages do`. Op-sequence body. Replaces the implicit "auto-fire
  at mount" default with explicit firing.

- **`when_connected do <ops> end`** inside `mount` — guard for ops
  that only run on the websocket mount (subscribe to PubSub,
  schedule timers, etc.). Replaces inline
  `if Phoenix.LiveView.connected?(socket) do ... end`.

- **Action body ops** — `push_patch`, `redirect`, `push_event`
  available alongside `set`/`run`/`effect`/`fire`/`navigate`/`emit`.

### Added — LV callback parity coverage

Paired test fixtures exercising each LiveView callback against both
vanilla Phoenix.LiveView and lavash. Lavash DSL covers the
callback's intent declaratively; the test asserts both expressions
produce the same observable behaviour. Coverage:

- `mount/3` + `state from: :session` + `temporary_assigns:`
- `handle_event/3`
- `handle_params/3`
- `handle_info/2`
- `render/1` + slots
- `on_mount` chains
- `assign_async/3` + `start_async/3` + `handle_async/3`
- Cross-module functional components (the new `components do` block)
- LiveComponents (stateful child views)

Still pending: streams, uploads, `terminate/2`, `format_status/2`.

### Added — JS pipeline architecture

- **`lavash({ concerns })` factory** in `priv/static/lavash.js` —
  returns a decorator that wraps any user hook. Auto-activates on
  elements with `data-lavash-state`; no-ops on others.

- **Four concern modules** at `priv/static/concerns/`:
  `optimisticActions`, `bindings`, `forms`, `overlays`. Each is a
  plain object with optional named stage handlers + optional merge
  visitors. The user picks which to include.

- **`defaultConcerns`** export — the standard bundle of all four.

- **9-stage update pipeline** with documented `ctx` schema. See
  `priv/static/PIPELINE.md` for the architecture: stage names,
  ctx fields, concern interface, merge visitor protocol.

- **Visitor-based merge walker** at `priv/static/merge_walker.js` —
  replaces the inline `mergeServerState` method on the old hook.
  Concerns register handlers keyed by path pattern
  (`emptyParams`, `serverErrors`, `animatedPhaseField`,
  `paramsCleared`, `skipServerErrorClear`).

- **`data-modal-phase` / `data-flyover-phase` attributes** —
  surfaced server-side and updated client-side from the SyncedVar
  phase machine. Makes phase transitions directly observable in
  the DOM for tests.

### Added — Test infrastructure

- **Latency-aware e2e safety net** — 10 tests under
  `test/integration/{latency,panel_latency}_test.exs` exercising
  optimistic UI under simulated latency. Uses LiveView's built-in
  `enableLatencySim()` + wallabidi 0.4.0-rc.3's `with_latency` /
  `click(q, await: :defer)` / `await_patch`. Covers the
  scalar/boolean/array optimistic paths and 9 of 11 modal phase
  machine transitions.

- **`ModalAsyncComponent` fixture** at `/magic/modal-async-host` —
  modal with `async_assign :item` for testing the entering →
  loading → visible branch.

### Changed

- Default e2e driver switched from Lightpanda to Chrome CDP.
  Lightpanda doesn't reliably fire `phx-hook` `mounted()` callbacks
  in our test setup — the optimistic patch from `LavashOptimistic`
  never ran, so latency tests silently observed only the
  server-reconciled state. Chrome CDP works correctly.

- Wallabidi upgraded to `0.4.0-rc.3`. Adds `with_latency/3`,
  `await: :defer` on interaction primitives, and `await_patch/2`.

- Mount lifecycle runs via a generated
  `__lavash_mount_lifecycle__/1` hook called from inside
  `Lavash.LiveView.Runtime.mount/4` — so a user-overridden
  `mount/3` (still needed for things like `temporary_assigns:`)
  still picks up `mount do ... end` block ops.

### Fixed

- `removeEventListener` in the old hook's `destroyed()` bound fresh
  function references, so listeners were never actually removed —
  they leaked across hook teardowns. The new concern modules stash
  bound refs at mount and use the same refs at destroy.

- Console clutter: 26 of 27 `console.warn` calls were diagnostic
  state-machine breadcrumbs polluting normal dev tools output.
  Downgraded to `console.debug`. The one genuine warning (the
  `data-lavash-animated` parse-failure message) stays as
  `console.warn`.

## [0.3.0-rc.5] — 2026-05-25

### Fixed

- **#19** — `rx()` dep extraction loses `@field` references nested
  inside the *key* of a bracket-access whose root isn't an @-ref.
  Example: `rx(@a && (@b || @c)[@d])` lost `:d` from deps. The AST
  rewrite was correct (the calc evaluated to the right value when
  called fresh), but the reactive engine didn't track the missing
  dep — so the calc never recomputed when that field changed, and
  the cached value (often `nil`) leaked through.

  Worse than the rc.3 → rc.4 fix-target: this same shape used to
  raise a hard crash on Elixir 1.18, then rc.3 quieted the crash
  without finishing the dep walk, producing a silent wrong-result.
  rc.5 closes the loop.

## [0.3.0-rc.4] — 2026-05-25

A round of compile-time validation to surface typos and stale
references before they become runtime crashes or silent nil
values. No runtime behaviour changes.

### Added

- **`Lavash.Transformers.ValidateDsl`** — a new transformer that
  runs after entity expansion and before compilation, raising
  `Spark.Error.DslError` with a clear hint when it spots:
  - duplicate `state`, `calculate`, or `action` names
  - a calculation whose name shadows a state of the same name
  - `reads [:foo]` where `:foo` matches no state, calc, read, prop,
    or form-derived field (previously a runtime `KeyError`)
  - `set :foo, ...` where `:foo` isn't a declared state
    (previously a silent socket-assign write)
  - `set ..., rx(@field)` or `calculate :foo, rx(@field)` where
    `@field` references an undeclared name (previously evaluated
    to nil silently)
  - action guards (`action :foo, [], [:guard]`) referencing names
    that aren't a state or calculation
- **`<input field={@form[:typo]}>` warning** — the template
  transformer now logs a dev-only warning when the field name
  isn't an attribute of the Ash resource behind the form,
  listing the available attributes. Silent when the resource
  couldn't be loaded at compile time.

### Fixed

- The bare-`{@field}` non-optimistic diagnostic no longer fires
  for props in components. Props are constant for the
  component's lifetime — they don't have an optimistic flavour,
  and rendering them bare is the correct pattern.
- `bind={[child: :parent]}` no longer warns when `:parent` is a
  declared prop on the host. `all_state_fields` in template
  metadata now includes prop entries alongside state.

## [0.3.0-rc.3] — 2026-05-25

Two more adopter-feedback fixes, both real runtime crashes on
recent Elixir versions and/or with idiomatic Elixir code.

### Fixed

- **#17** — `rx()` handles `@field` references nested inside path-access
  keys and short-circuit operators. Two related bugs were fixed in one
  pass:
  - The walker rewrote `@params` in `rx(@params["x"])` but left a key
    that was itself an @-ref (`rx(@params[@k])`) raw, so it survived
    into the stored AST and crashed at eval time with
    `Module.get_attribute against an already-compiled module`.
  - `Kernel.&&/2`, `Kernel.||/2`, `Kernel.and/2`, `Kernel.or/2` expand
    eagerly on some Elixir versions (notably 1.18.x), hiding inner
    `@field` refs from the walker. Now pre-expanded only when needed
    so the walker sees a canonical shape across versions.
- **#18** — `calculate :foo, rx(local_helper(@x))` resolves unqualified
  calls to local helpers — both `def` and `defp` — at runtime. Same
  root cause and fix shape as rc.2's #15 for action `run fn` bodies:
  each calculation's rx body is hoisted at compile time into a
  generated `def __lavash_calc__/2` on the user's module, so local
  resolution (which covers `defp`) takes over. Public functions
  worked before via `module.fun(...)` qualification, but `defp`
  wasn't remote-callable and crashed.

### Tooling

- `mix docs --warnings-as-errors` runs as the fifth step of the
  optional pre-commit hook (`.githooks/pre-commit`). Catches
  `Module.fun/n` references in moduledocs / CHANGELOG that point at
  since-removed functions — those previously slipped through to
  published docs because `mix docs` exits 0 even with warnings.

## [0.3.0-rc.2] — 2026-05-25

Five fixes prompted by a second round of adopter feedback. All five
issues opened against the repo were closed.

### Fixed

- **#12** — Action `reads [:some_calc]` now resolves correctly when
  `:some_calc` is a `calculate :foo, rx(...)` field. The runtime built
  the action's assigns map from declared state only, skipping derived
  values. Switched to `LSocket.full_state/1` to match the rest of the
  runtime (which already used `full_state`); the previous behaviour
  was an inconsistency, not a deliberate restriction.
- **#13** — `run fn` bodies can now read non-Lavash socket assigns
  (`@current_user` set by `AshAuthentication.on_mount`, a tenant set
  by a plug, etc.) without re-declaring them as Lavash state. The
  assigns map is built from the full `socket.assigns`, with event
  params layered on top so `phx-value-*` still wins over a stray
  socket assign of the same name. Lifting auth-derived values into
  Lavash state via `Lavash.Socket.put_state/3` remains the recommended
  pattern but is no longer required.
- **#15** — Unqualified calls to private helpers (`defp helper(...)`)
  inside `run fn` bodies now resolve at runtime. The body was
  previously evaluated via `Code.eval_quoted` + `:erl_eval`, which has
  no local function table; calls raised `UndefinedFunctionError` even
  though the compiler tracked the references (rc.1's #11 fix). Each
  `run fn` body is now hoisted into a generated
  `def __lavash_run__(action_name, idx, assigns)` on the user's
  module, so local helpers, aliases, imports, and module attributes
  are all in scope. The runtime invokes it via `apply/3`.
- **#16** — The auto-injector no longer wraps `{@field}` body
  expressions inside `<textarea>`, `<option>`, or `<title>`. Browsers
  treat these elements' body content as a value (submitted form data,
  displayed option label, page title), so the literal
  `<span data-lavash-display="...">N</span>` HTML was corrupting the
  form payload.

### Added

- **#14** — New "Cookbook: a full form-submission recipe" section in
  the README. One end-to-end example showing `use Lavash.LiveView` +
  AshAuthentication `on_mount` + URL state with `url_name:` + ephemeral
  optimistic state bound to form inputs + `calculate` + custom
  `mount/3` chaining into `Runtime.mount/4` + `Lavash.Socket.put_state/3`
  for seeding from auth + `action :submit, [...]` to read submit
  payload + a `run fn` calling a private helper.

### Internal

- Lavash.Action.Runtime.apply_runs/4 becomes apply_runs/5 (takes
  the action name). The runtime no longer uses
  Lavash.Rx.Cache.compile_run_fun/2; that function and its test are
  removed.

## [0.3.0-rc.1] — 2026-05-25

A follow-up to 0.3.0-rc.0 that bumps to Phoenix LiveView 1.2-rc, adds a
new template-declaration shape, and addresses four issues filed by the
first external adopter.

### Added

- **`template do ~H"..." end` template-declaration shape**, alongside
  the existing `render fn assigns -> ~L"..." end`. Both compile to the
  same `render/1` and go through the same auto-injection pipeline. The
  new shape uses the standard `~H` sigil (no custom sigil required) and
  is the recommended way to declare templates going forward. The `~L`
  shape stays supported and is still the only path that works with
  `render_loading fn` for animated overlays.
- **`url_name:` option on `state from: :url`** so the URL key can differ
  from the field name (`state :subject_handle, from: :url, url_name: "subject"`).
  When a `from: :url, required: false` field falls back to its default and
  the configured key isn't in params, lavash logs a dev-only warning
  naming the missing key and what keys WERE present — turns silent
  typos into a debuggable signal.
- **Compile-time tracking of helper function references inside action
  `run fn` bodies.** The bodies were previously captured as quoted AST,
  hiding helper-function call sites from the compiler. Builds with
  `--warnings-as-errors` no longer fail on `defp helper/1 is unused`
  warnings for helpers used only inside action bodies.
- **`Lavash.SparkHeex` spike**: a Spark extension that treats HEEx
  templates as first-class DSL data. Transformers cross-validate
  `@field` refs against declared `state` entities, `phx-click="event"`
  refs against declared `action` entities, and `phx-value-*` keys
  against declared action params — all at compile time, raising
  `Spark.Error.DslError` with file/line on mismatch. Not yet integrated
  into the main DSL; lives as a parallel module.

### Changed

- **`mount/3` generated by `use Lavash.LiveView` is now `defoverridable`.**
  Users who define their own `def mount/3` to do per-route setup can
  chain into `Lavash.LiveView.Runtime.mount/4` to attach the reactive
  graph. Previously the user's `mount/3` silently shadowed the
  framework's, causing the first `handle_params/3` to crash deep in
  `Reactive.get_graph!`.
- **`phoenix_live_view` dependency bumped to `~> 1.2-rc`.** LV 1.2
  restructured `Phoenix.LiveView.TagEngine` into a behaviour plus
  `Parser`/`Compiler`/`Tokenizer` private modules. Lavash's previously
  1828-line fork of TagEngine is now an 85-line shim that wraps the new
  upstream API. The token transformer (auto-injection) was rewritten to
  walk the new `:block`/`:self_close` node tree instead of a flat
  token list. Behaviour is unchanged.

### Fixed

- `caller.function` is set to a synthetic `{:render, 1}` when lavash
  compiles a template from a Spark transformer's module-define-time
  env, so LV 1.2's `HTMLEngine.annotate_body/1` doesn't crash under
  `debug_heex_annotations`.
- `:strip_eex_comments` is set on parser invocations so the compiler
  doesn't trip on `{:eex_comment, _}` nodes (which it only expects in
  whitespace filtering).
- `Lavash.Sigil.sigil_L/2` now calls `Phoenix.LiveView.TagEngine.compile/2`
  directly. The deprecated `EEx.compile_string(template, engine: ...)`
  path no longer works on LV 1.2.

### Documented (not fixed)

- **`data-lavash-bind` syncs asynchronously**, so a fast tick-then-submit
  on a `<form phx-submit="...">` can post before the bind reaches the
  server. The action body sees `@confirmed = false` even though the
  checkbox is visually checked. Two workarounds are documented in the
  README ("Forms vs. `data-lavash-bind` on submit"): prefer
  `<.form for={@some_form}>` for submit flows, or read the form params
  inside the action body via `params [...]` instead of through
  `@field`. A future release will close this gap.

## [0.3.0-rc.0] — 2026-05-24

This release is a substantial overhaul of the DSL and template surface from
0.2.0. It collapses several legacy paths into the modern `calculate` /
`rx()` / `~L` model, introduces a non-DSL on-ramp (`Lavash.LiveView.Explicit`),
and adds compile-time machinery (auto-injection, diagnostics, optimistic
JS hook integration) that lets the user write near-vanilla Phoenix HEEx
with reactive behavior wired in for free.

### Breaking changes

- **Removed the `derive` DSL block.** `derive :name do argument ... run/compute end`
  no longer compiles. Use `calculate :name, rx(...)` instead — the modern
  form already does what `derive` did, plus transpiles to JS for the
  optimistic path. Migration is mechanical: convert each `argument`
  declaration to a state/derive reference inside the `rx(...)` body.
- **Removed the `update :field, fn` action operation.** Use
  `set :field, rx(...)` instead — same Elixir semantics plus client-side
  transpilation. Mechanical migration:
  - `update :count, &(&1 + 1)` → `set :count, rx(@count + 1)`
  - `update :flag, &(!&1)` → `set :flag, rx(not @flag)`
  - `update :n, fn n -> (n || 0) + 1 end` → `set :n, rx((@n || 0) + 1)`
- **Removed the `notify_parent :event` action operation.** No usage anywhere
  in this repo's demo or fixtures, and `bind=` + PubSub cover the
  state-sync and cross-process cases. For the genuine "child fires a
  callback on its parent" case, use `send(self(), {:my_event, payload})`
  inside a `run fn` and pattern-match in `handle_info/2`.
- **Removed `Lavash.Argument`** (the derive-specific argument struct).
  Read-side arguments use `Lavash.Read.Argument` and are unaffected.
- **Removed `Lavash.Actions.Update`** and `Lavash.Actions.NotifyParent`
  structs, along with their runtime helpers.
- **Removed the `:lavash_component_*` message tag family** (`_set`, `_close`,
  `_delta`, `_add`, `_remove`, `_toggle`) in favor of a single
  `{:lavash_field_op, op, field, value}` envelope. The `_delta`/`_close`/etc.
  handlers were dead code anyway; the `_set` handler is now reached via
  the new envelope.
- **`~L` is required** for Lavash LiveView and Component render functions —
  `~H` works but skips the lavash template transformer (no auto-injection,
  no diagnostics). Existing code should already be on `~L`; this is a
  documentation clarification rather than a runtime change.
- **Test fixtures renamespaced.** `Lavash.Test*` modules in `test/support/`
  moved to `Lavash.Test.Magic.*` (DSL fixtures) and a new
  `Lavash.Test.Explicit.*` namespace (plain Phoenix.LiveView fixtures).
  Demo applications consuming these fixtures (none expected) need to update.

### Added

- **`Lavash.LiveView.Explicit`** — non-DSL entry point. `use
  Lavash.LiveView.Explicit` + a `reactive do state ... derive ... end`
  block gets you the reactive graph with `put_state/3`, automatic mount,
  and async-derive dispatch, but no template transformer, no
  optimistic JS hook, no forms/overlays/bindings. For "I want the
  reactive engine but not the rest."
- **Compile-time diagnostics** in the `~L` template transformer:
  - Warn when a bare `{@field}` references a declared-but-non-optimistic
    state field (likely missing `optimistic: true`).
  - Warn when `bind={[child: :parent]}` targets a `:parent` that isn't a
    declared state field on the host.
- **Auto-injection** of more `data-lavash-*` attributes from natural
  Phoenix HEEx patterns:
  - `class={if @bool, do: A, else: B}` on an optimistic boolean →
    auto-injects `data-lavash-toggle`.
  - `class={if val in @list, do: A, else: B}` on an optimistic array →
    auto-injects `data-lavash-member` + `data-lavash-member-value`.
  - `<.lavash_component bind={[n: :p]}>` → auto-injects `n={@p}` so the
    child receives the parent's value.
- **Compile-time graph cache invalidation.** `Lavash.Dsl.Graph`,
  `Lavash.Reactive`, and `Lavash.Rx.Cache` register `@after_compile`
  hooks that drop their `:persistent_term` cache entries when a Lavash
  module recompiles in dev. Renamed fields and removed calculations
  no longer carry stale compute fns across reloads.
- **AST eval cache** (`Lavash.Rx.Cache`) — user-supplied ASTs in `rx()`
  expressions and `run` functions are compiled once and stored in
  `:persistent_term`, replacing the per-fire `Code.eval_quoted` cost.
- **Browser-driven integration tests** via Wallabidi + Lightpanda. 61
  end-to-end tests cover counters, bindings, DOM directives, forms,
  arrays, overlays, optimistic state, and reconnects against real
  Lightpanda. The lavash JS hook is loaded into the test layout.
- **`Lavash.LiveView.Compiler.collect_optimistic_fields/1`** — public
  accessor for "state fields that should be optimistic" (both
  explicitly declared and implicitly via action-touched).
- **`Lavash.State.MissingRequiredFieldError`** structured exception
  replacing the old bare-string raise in URL field hydration.
- **`Lavash.Form.Runtime.extract_submit_errors/1`** — single home for
  the Ash-error-to-field-error-map conversion that was duplicated in
  five places.
- **`Lavash.Type.decode_wire/1`** — JS-wire decoder unifying the
  previously-duplicated `parse_value/1` and `parse_binding_value/1`.
- **`Lavash.Component.CompilerHelpers.resource_available?/1`** —
  unified the previously-duplicated Ash resource compile-readiness check.
- **`__lavash__(:declared_actions)` and `__lavash__(:derives)`** —
  introspection accessors for callers that need the un-augmented
  user-declared entities (vs. the `:actions` accessor which also
  includes synthetic setters and optimistic actions).

### Changed

- **Bindings are now bidirectional.** The template transformer
  auto-injects the parent's bound-field value into the child's assigns,
  so the child sees parent updates as well as propagating its own
  writes back. Sibling components bound to the same parent field stay
  in sync via the parent.
- **User callbacks are overridable.** `handle_params`/`handle_event`/
  `handle_info` on LiveViews and `update`/`handle_event` on Components
  now have `defoverridable` declared, so users can write their own
  clauses and call `super/N` to fall through to the lavash dispatch.
- **`:lavash_*` catch-all logs.** The `handle_info` catch-all in
  `Lavash.LiveView.Runtime` logs a warning when an unrecognized
  `:lavash_*` tuple arrives instead of silently dropping it. Library
  bugs surface in the log instead of vanishing.
- **`component_states` routed through assigns**, not the process
  dictionary. The per-component-id state map (used to restore socket
  state across reconnects) now travels via `@__lavash_component_states__`
  and propagates through nested `<.lavash_component>` calls. Visible
  in change tracking and in tests.
- **Three DSL metadata access patterns reduced to a clear partition.**
  `Transformer.get_entities` for compile time, `module.__lavash__/1`
  for the canonical runtime accessor, and `Spark.Dsl.Extension.get_entities/2`
  as an escape hatch for the few callers that need un-augmented
  entities.
- **Phoenix.HTML.FormData protocol on `Lavash.Form`** now implements
  `to_form/4`, `input_value/3`, and `input_validations/3`. Nested form
  inputs (`<.inputs_for>`) now work end-to-end.
- **Default Elixir/OTP versions pinned.** `.tool-versions` declares
  `elixir 1.19.0-otp-28` / `erlang 28.1`.
- **Pre-commit hook ships in `.githooks/`.** Opt in with
  `git config core.hooksPath .githooks`. Runs format, compile
  --warnings-as-errors, credo --strict, and the full test suite.
- **Credo strict clean.** The repo passes `mix credo --strict` with no
  findings; the pre-commit hook keeps it that way.

### Fixed

- **`apply_runs/4` was silently no-op for any non-initial action.**
  `Phoenix.Component.assign` stores either `true` (initial render) or
  the *old value* (subsequent change) in `__changed__`; the old code
  pattern-matched only on the literal `true` and dropped every
  subsequent run-based action's writes. Now it accepts any marker.
- **`inside_display_element?` mis-tracked depth for void elements.**
  `<input>`, `<br>`, etc. produce a `:tag` token with no matching
  `:close`, so they wrongly consumed the depth-0 slot when scanning
  back through the accumulator. Now skipped via `closing: :void` /
  `closing: :self` in tag meta.
- **`Rx.qualify_local_calls` broke imported helpers.** Bare calls were
  rewritten to `Caller.fn(...)` regardless of whether the name was
  imported from another module. Now consults `__CALLER__.functions` /
  `.macros` and qualifies against the import's source module.
- **Silent `try/rescue` around `apply_submits` removed.** Used to swallow
  every exception, set a `[DEBUG] Exception in submit` flash, and
  return `{:ok, socket}` — bypassing the user's `on_error` action.
  Now unexpected exceptions crash the LiveView per Phoenix conventions;
  validation failures still route through `{:error, form_with_errors}`
  to `on_error`.
- **`optimistic_state/2` no longer evaluates async calculations
  synchronously.** Calling the user's `slow_fn` inside render blocked
  mount and bypassed the AsyncResult flow.
- **Reactive graphs are no longer evaluated stale after recompile.**
  See "Added: Compile-time graph cache invalidation."

### Removed

- Files: `lib/lavash/argument.ex`, `lib/lavash/actions/update.ex`,
  `lib/lavash/actions/notify_parent.ex`.
- DSL entities: `:derive`, `:update` (the action op, not Ash's update),
  `:notify_parent`.
- The `<.o>` display helper (deprecated long ago; `~L` auto-wraps bare
  `{@field}` instead).
- Pre-DSL `data-optimistic-*` attribute family (`data-optimistic`,
  `-display`, `-field`, `-value`). The current API is `data-lavash-*`,
  auto-injected by `~L`.
- The stale "Architecture" section in README that described
  `socket.private.lavash` as the state store — state lives in
  `socket.assigns` eagerly written by `LSocket.put_state/3`.
- Five duplicate copies of `extract_submit_errors/1`, two of
  `parse_value`/`parse_binding_value`, two of `resource_available?/1`.
- The process-dictionary side channel for `component_states`.

[Unreleased]: https://github.com/u2i/lavash/compare/v0.4.0-rc.5...HEAD
[0.4.0-rc.5]: https://github.com/u2i/lavash/compare/v0.4.0-rc.4...v0.4.0-rc.5
[0.4.0-rc.4]: https://github.com/u2i/lavash/compare/v0.4.0-rc.3...v0.4.0-rc.4
[0.4.0-rc.3]: https://github.com/u2i/lavash/compare/v0.4.0-rc.2...v0.4.0-rc.3
[0.4.0-rc.2]: https://github.com/u2i/lavash/compare/v0.4.0-rc.1...v0.4.0-rc.2
[0.4.0-rc.1]: https://github.com/u2i/lavash/compare/v0.3.0-rc.5...v0.4.0-rc.1
[0.3.0-rc.0]: https://github.com/u2i/lavash/compare/v0.2.0...v0.3.0-rc.0
