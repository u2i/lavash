# Test support fixtures

Fixtures used by the e2e integration tests under `test/integration/`. They're
split into two parallel implementations of the same observable behavior:

## `magic/` — DSL-driven

Uses the full Lavash DSL: `use Lavash.LiveView`, `state`, `calculate`, `rx`,
`actions do ... end`, `template do` blocks with auto-injected `data-lavash-*`
attributes. The template transformer and the LavashOptimistic JS hook do
most of the work.

Modules live under `Lavash.Test.Magic.*` and routes under `/magic/*`.

This is the path lavash users normally take.

## `explicit/` — Plain Phoenix

Plain `use Phoenix.LiveView` with `handle_event`, `handle_params`, manual
`recompute` after state mutations, `~H` templates. No DSL, no transformer,
no lavash JS hook in the rendered output.

Modules live under `Lavash.Test.Explicit.*` and routes under `/explicit/*`.

This is "how much would I have to write by hand without lavash?" — useful
both as a sanity check and as a baseline for measuring what the DSL is
actually doing for you.

## Coverage

| Feature | Magic | Explicit |
|---|---|---|
| Counter (URL-backed state, basic actions) | ✓ | ✓ |
| Chained calculations | ✓ | ✓ |
| Ephemeral chain | ✓ | ✓ |
| Async derives | ✓ | ✓ (via `assign_async`) |
| URL state hydration | ✓ | ✓ |
| Path params | ✓ | — |
| Component bindings (parent ↔ child sync) | ✓ | — |
| Component nesting + binding chain | ✓ | — |
| `data-lavash-*` directives | ✓ | — |
| Optimistic state (client-side updates) | ✓ | — |
| Array state + derived length/joined | ✓ | — |
| Ash forms + auto-validation | ✓ | — |
| Modal phase machine | ✓ | — |
| Guarded actions | ✓ | — |

The features marked "—" on the explicit side don't have meaningful
counterparts: they're the lavash DSL. Replicating them by hand would be
"copy-paste lavash's `data-lavash-*` machinery and JS hook into your own
app," which defeats the point of having two implementations.

The integration tests parameterize over both prefixes where a meaningful
comparison exists (calculations, url_state, smoke). Magic-only features
keep their `/magic/*` assertions.

## Adding a new explicit fixture

If you add a new magic fixture and there's a sensible plain-Phoenix
equivalent, mirror it under `test/support/explicit/` and add a route. Then
parameterize the relevant integration test with:

```elixir
for {label, prefix} <- [{"magic", "/magic"}, {"explicit", "/explicit"}] do
  @prefix prefix

  describe "your feature (#{label})" do
    test "...", %{session: session} do
      session |> visit(@prefix <> "/your-route") |> ...
    end
  end
end
```
