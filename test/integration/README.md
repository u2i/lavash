# Integration tests (Wallaby)

Browser-driven end-to-end tests for the lavash demo app. These stubs describe
behavior that can only be verified with a real browser — JS hooks, optimistic
DOM updates, animation phases, client-side validation, binding propagation, etc.

The demo app (`demo/`) exercises the full range of lavash features and is the
intended target for these tests, but the tests are organized by **capability**,
not by demo page. A single test may visit any demo route that happens to
exercise the relevant behavior.

All tests are currently empty pending-style stubs (`assert true`) with a
docstring describing the goal. Wallaby is not yet wired up.

Tagged `@moduletag :e2e` and excluded from the default `mix test` run.
Run them explicitly with:

```
mix test --include e2e test/integration
```

