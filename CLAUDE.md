# Claude Development Notes

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
