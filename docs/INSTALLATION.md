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

## Colocated JS (required for optimistic behavior)

Lavash ships each component's generated optimistic JavaScript through
Phoenix LiveView's [colocated JS](https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.ColocatedJS.html)
system — the same mechanism as colocated hooks. Follow LiveView's
setup (the `:phoenix_live_view` mix compiler, the `reloadable_compilers`
entry in dev, and your bundler's `NODE_PATH`); recent `mix phx.new`
projects have it out of the box.

The lavash-specific part: import **both** manifests in `app.js` —
your app's and lavash's own. The generated modules self-register on
import, so these bare side-effect imports are all the wiring needed:

```javascript
import "phoenix-colocated/lavash";
import "phoenix-colocated/my_app";
```

This setup is load-bearing for optimism specifically: if the compiler
or the imports are missing, nothing errors — every optimistic action
silently degrades to a server round-trip. The app looks fine on
localhost and is visibly laggy under real latency.

## Client setup

To enable lavash on the client side in `app.js`:

```javascript
import { lavash, defaultConcerns, getHooks, getState } from "lavash";

import "phoenix-colocated/lavash";
import "phoenix-colocated/my_app";

const lavashDecorator = lavash({ concerns: defaultConcerns });

const liveSocket = new LiveSocket("/live", Socket, {
  params: () => ({ _csrf_token: csrfToken, _lavash_state: getState() }),
  hooks: getHooks(lavashDecorator, MyAppHooks)
});
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
