# Quick Start

The same counter, evolved one layer at a time. Each step adds one
capability and shows what tradeoff it brings.

## Just the DSL (layer 1)

```elixir
defmodule MyAppWeb.CounterLive do
  use Lavash.LiveView

  actions do
    action :increment do
      run fn socket ->
        Phoenix.Component.assign(socket, :count, socket.assigns.count + 1)
      end
    end

    action :reset do
      run fn socket -> Phoenix.Component.assign(socket, :count, 0) end
    end
  end

  template do
    ~H"""
    <div>
      <p>Count: {@count}</p>
      <button phx-click="increment">+</button>
      <button phx-click="reset">Reset</button>
    </div>
    """
  end
end
```

This is just vanilla LiveView with the DSL on top: `phx-click` resolves
to a declared `action`, the compiler validates the event names against
the actions block, and the template references `@count` like any HEEx.
What you get for free over hand-written `handle_event` clauses is the
uniform op vocabulary and the cross-validation.

## Add declarative state (layer 2)

```elixir
state :count, :integer, from: :url, default: 0

actions do
  action :increment do
    set :count, rx(@count + 1)
  end

  action :reset do
    set :count, 0
  end
end
```

`from: :url` makes `@count` part of the query string —
`/counter?count=5` is deep-linkable, refresh-safe, and bookmarkable.
`set :count, rx(...)` replaces the `run fn` body — lavash knows how
to write the field and trip the URL update. Other sources are
`:socket` (reconnect-survival, JS-side cache), `:session` (Phoenix
session-backed), `:assigns` (lift an existing `on_mount`-injected
assign, e.g. `@current_user`, into lavash state), and `:ephemeral`
(process-only, the default).

## Add reactivity (layer 3)

```elixir
state :count, :integer, from: :url, default: 0
state :multiplier, :integer, from: :ephemeral, default: 2

calculate :doubled, rx(@count * @multiplier)
```

`calculate :doubled, rx(...)` adds a derived field. The reactive
graph tracks `@count` and `@multiplier` as dependencies; lavash
recomputes `:doubled` whenever either changes, in topological order.
Async derives are a flag away (`async: true`). All eval happens
server-side; the result flows through the normal LiveView diff.

## Add optimistic UI (layer 4)

```elixir
state :count, :integer, from: :url, default: 0, optimistic: true
state :multiplier, :integer, from: :ephemeral, default: 2, optimistic: true

calculate :doubled, rx(@count * @multiplier)
```

`optimistic: true` causes the rx transpiler to emit JS for the
`set :count, rx(@count + 1)` operation, the template transformer to
auto-inject `<span data-lavash-display="count">{@count}</span>` and
`<span data-lavash-display="doubled">{@doubled}</span>`, and the
`LavashOptimistic` JS hook to apply the prediction client-side
before the server reply arrives. The merge walker reconciles when
the authoritative reply lands. Server is still the source of truth;
optimism is a UX shim in front of it.

## Custom `mount/3`

Lavash generates a `mount/3` that initialises the reactive graph (state
hydration, dependency graph, PubSub subscriptions). For most mount-time
setup — firing async tasks, subscribing to PubSub, scheduling timers —
the declarative `mount do ... end` block (see
[Lifecycle blocks](docs/LAYER_1_BASE_DSL.md#lifecycle-blocks)) is the better fit; it runs after
the runtime mount and doesn't require chaining.

When you need something the block doesn't cover — `temporary_assigns:`
on the return tuple, code that has to run *before* the runtime mount,
or assigns the runtime doesn't manage — the generated `mount/3` is
`defoverridable`. Chain into `Lavash.LiveView.Runtime.mount/4` first so
the reactive graph gets attached to the socket:

```elixir
def mount(params, session, socket) do
  {:ok, socket} = Lavash.LiveView.Runtime.mount(__MODULE__, params, session, socket)

  # ...your per-route setup
  {:ok, Phoenix.Component.assign(socket, :greeting, lookup_greeting(params))}
end
```

If you skip the `Runtime.mount/4` call, the first `handle_params/3` will
crash with `Reactive graph not found on socket` — the reactive layer relies
on graph state being initialised at mount time.
