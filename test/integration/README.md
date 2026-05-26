# Browser e2e tests

Browser-driven end-to-end tests covering the JS half of lavash.
These run **by default** alongside the rest of `mix test` — they're
not optional. Lavash's value prop is half JavaScript (optimistic
UI, modal phase machine, client-side rx evaluation,
`data-lavash-*` DOM updates), so a unit-only test pass doesn't
prove the framework works.

## What's covered

| File | What the browser exercises |
|---|---|
| `smoke_test.exs` | LiveView mounts and renders |
| `actions_test.exs` | phx-click → action → DOM update |
| `calculations_test.exs` | Dep change → calc recompute → DOM reflects |
| `forms_test.exs` | Type into inputs, validation derives, submit cycle |
| `optimistic_state_test.exs` | Client patches DOM before server reply |
| `latency_test.exs` | Optimistic patches are sub-latency |
| `panel_latency_test.exs` | Modal/flyover phase timing under latency |
| `overlays_test.exs` | Modal/flyover open, async load, close, escape, backdrop |
| `dom_directives_test.exs` | All `data-lavash-*` annotations render + update |
| `bindings_test.exs` | Parent/child component binding chains propagate |
| `arrays_and_keyed_test.exs` | `map_by` keyed array mutations preserve DOM identity |
| `checkbox_bind_test.exs` | Checkbox/radio/select binding (regression) |
| `url_state_test.exs` | URL ↔ state two-way sync via `history.replaceState` |
| `reconnect_test.exs` | `from: :socket` state survives websocket reconnect |

Each test boots a real `Lavash.TestEndpoint` on port 4002 and
drives Chrome via Wallabidi's CDP driver against fixtures in
`test/support/magic/`.

## Running

```sh
# Default — runs e2e + unit
mix test

# Skip e2e (faster, but a green run doesn't prove JS works)
LAVASH_NO_E2E=1 mix test
# or
mix test --exclude e2e
```

## Chrome discovery

Wallabidi drives a local Chrome via CDP. The test helper
auto-discovers the standard macOS install at
`/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`.

Override with:

```sh
WALLABIDI_CHROME_PATH=/path/to/chrome mix test    # local binary
WALLABIDI_CHROME_URL=chrome:9222 mix test         # remote CDP endpoint
```

If you see `(Wallabidi.DependencyError) Chrome not found`, one of
the above is missing.

## Per-test infrastructure

Each test module uses `Lavash.IntegrationCase`, which:

- carries `@moduletag :e2e`
- starts a fresh Wallabidi session in `setup`
- provides a `%{session: session}` to test bodies
- ends the session on exit

The session is async-unsafe; use `async: false`.

## Adding a new e2e test

1. Add a fixture LiveView under `test/support/magic/` if you need
   one (most behaviors have a fixture already).
2. Wire a route in `Lavash.TestRouter` (see existing routes).
3. Write the test with `use Lavash.IntegrationCase, async: false`.
4. Run `mix test test/integration/<your_test>.exs` to verify.

Tests time out after 5 seconds per Wallabidi default. Override per
test with `@tag wallabidi_timeout: 10_000` if you're testing
latency-aware behavior that genuinely needs more.
