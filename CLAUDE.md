# Claude Development Notes

## Git Commits

Commit freely as work lands. You do not need to wait for explicit
user approval before each commit in this repo — the pre-commit
hook (`.githooks/pre-commit`) gates everything that matters:
format, compile with warnings-as-errors, credo --strict, the full
test suite (unit + browser e2e), and docs with warnings-as-errors.
If the hook chain passes, the commit is safe to land. If it
fails, fix the underlying issue rather than passing `--no-verify`.

Do not include co-author attribution in commit messages.

## Testing — e2e is load-bearing, not optional

Lavash's behavior is roughly half JavaScript (optimistic UI,
SyncedVar merge walker, modal phase machine, `data-lavash-*`
DOM updates, client-side rx evaluation). The unit tests in
`test/lavash/` verify the Elixir transformers; only the
browser-driven e2e tests in `test/integration/` verify the JS
actually does what the Elixir said it should.

Treat e2e tests as a **default-on** part of the suite. Never
describe them as "skipped by default" or "optional" — they
literally run on `mix test` (see `test/test_helper.exs`). The
opt-out exists for fast inner-loop dev (`LAVASH_NO_E2E=1`), not
because they're a separate suite.

When asserting "all tests pass," that claim must mean **including
e2e**. A unit-only pass does not prove lavash works.

Browser is Chrome via Wallabidi CDP. The helper auto-discovers
the macOS Chrome install; override with `WALLABIDI_CHROME_PATH`
or `WALLABIDI_CHROME_URL`.

## Colocated Hooks Development Workflow

The demo app is configured for automatic reloading of colocated JS hooks from the lavash library.

When modifying JavaScript hooks in colocated `<script :type={Phoenix.LiveView.ColocatedHook}>` tags within Elixir files (like `lib/lavash/modal/helpers.ex`):

1. **Edit the Elixir file** containing the colocated hook
2. **Save the file** - Phoenix live reload will automatically:
   - Recompile the lavash dependency
   - Extract colocated hooks to `demo/assets/vendor/phoenix-colocated/lavash/`
   - esbuild detects the change and rebuilds
   - Browser reloads with new JS

### How it works

The demo app has these configurations:

- `config :phoenix_live_view, :colocated_js, target_directory: "assets/vendor/phoenix-colocated"` - writes hooks where esbuild can see them
- `reloadable_apps: [:demo, :lavash]` - Phoenix recompiles lavash on changes
- `reloadable_compilers: [:elixir, :app, :phoenix_colocated]` - includes the colocated hooks compiler
- esbuild `NODE_PATH` includes `assets/vendor/` to resolve `phoenix-colocated/lavash`

### Manual recompile (if needed)

If automatic reloading isn't working:

```bash
cd /Users/tom/dev/lavash/demo && mix deps.compile lavash --force
```
