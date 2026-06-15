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

To enable lavash on the client side in `app.js`:

```javascript
import { lavash, defaultConcerns, getHooks, getState } from "lavash";

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
