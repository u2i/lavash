# Installation

```elixir
def deps do
  [
    {:lavash, "~> 0.4.0-rc"}
  ]
end
```

Configure PubSub for cross-process invalidation:

```elixir
# config/config.exs
config :lavash, pubsub: MyApp.PubSub
```

## Compiler setup (required for optimistic JS)

Lavash generates each component's optimistic JavaScript at compile
time via Phoenix's colocated-JS system. That system's compiler must be
registered, **listed first** (it works by installing an after-compiler
callback on `:elixir`, so it has to run before `:elixir` does):

```elixir
# mix.exs
def project do
  [
    compilers: [:phoenix_live_view] ++ Mix.compilers(),
    ...
  ]
end
```

And in dev, so live reload keeps the generated-JS manifest fresh:

```elixir
# config/dev.exs
config :my_app, MyAppWeb.Endpoint,
  reloadable_compilers: [:elixir, :app, :phoenix_live_view]
```

> #### Warning {: .warning}
>
> The compiler is named `:phoenix_live_view` — there is no
> `:phoenix_colocated` compiler. Unknown names in
> `reloadable_compilers` are **silently ignored** by Phoenix, and the
> symptom is subtle: live reload regenerates the per-module JS files
> but never rebuilds the manifest that imports them, so the browser
> keeps running stale optimistic code (or none at all).

## Client setup

To enable lavash on the client side in `app.js`:

```javascript
import { lavash, defaultConcerns, getHooks, getState } from "lavash";

// Generated optimistic functions, extracted at compile time. Each
// module self-registers when imported — these bare side-effect
// imports are all the wiring needed. WITHOUT them, every optimistic
// action silently degrades to a server round-trip: the app looks
// fine on localhost and is visibly laggy under real latency.
import "phoenix-colocated/lavash";
import "phoenix-colocated/my_app";

const lavashDecorator = lavash({ concerns: defaultConcerns });

const liveSocket = new LiveSocket("/live", Socket, {
  params: () => ({ _csrf_token: csrfToken, _lavash_state: getState() }),
  hooks: getHooks(lavashDecorator, MyAppHooks)
});
```

For esbuild to resolve the `phoenix-colocated/*` imports, its
`NODE_PATH` must include the build directory where the compiler writes
them:

```elixir
# config/config.exs — in your esbuild profile
env: %{
  "NODE_PATH" =>
    Enum.join([Path.expand("../deps", __DIR__), Mix.Project.build_path()], ":")
}
```

`lavash({ concerns })` returns a decorator that wraps every hook
passed to `getHooks`. It auto-activates on elements that the server
runtime marks with `data-lavash-state` (lavash LiveViews, components,
overlays); on regular Phoenix hooks it passes through with zero cost.

`defaultConcerns` is the standard bundle (`optimisticActions`,
`bindings`, `forms`, `overlays`). To omit one — e.g. you never use
modals — replace with an explicit array:

```javascript
import { lavash, optimisticActions, bindings, forms, getHooks } from "lavash";

const lavashDecorator = lavash({
  concerns: [optimisticActions, bindings, forms]   // no overlays
});
```
