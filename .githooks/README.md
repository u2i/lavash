# Git hooks

Project-managed hooks. Opt in once per clone:

```
git config core.hooksPath .githooks
```

## `pre-commit`

Runs before every commit:

1. `mix format --check-formatted`
2. `mix compile --warnings-as-errors`
3. `mix credo --strict`
4. `mix test`

Any failure aborts the commit. The hook uses `mise exec --` if mise is on
PATH so the pinned `.tool-versions` toolchain is used; otherwise it falls
back to bare `mix`.

To skip the hook for a single commit (use sparingly):

```
git commit --no-verify
```
