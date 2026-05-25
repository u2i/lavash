# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/u2i/lavash/compare/v0.3.0-rc.0...HEAD
[0.3.0-rc.0]: https://github.com/u2i/lavash/compare/v0.2.0...v0.3.0-rc.0
