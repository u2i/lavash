# Cross-cutting concerns

## PubSub invalidation

```elixir
# In a read declaration
read :products, Product, :list do
  invalidate :pubsub
end

# In the Ash resource: which attributes trigger invalidation
defmodule MyApp.Product do
  use Ash.Resource, extensions: [Lavash.Resource]

  lavash do
    notify_on [:category_id, :in_stock]
  end
end
```

When a form submits, Lavash broadcasts to PubSub topics matching the
mutated resource. LiveViews with subscribed reads auto-refresh.

## Using lavash without the DSL

This is the layer-3-only escape hatch: the reactive engine, without the
DSL surface, the template transformer, the optimistic JS, or any of the
overlay / form / binding machinery.

`Lavash.LiveView.Explicit` exposes the reactive engine alone. You get
the dependency graph and automatic recomputation; you write `mount/3`,
`handle_event/3`, and `render/1` like any plain Phoenix LiveView.

```elixir
defmodule MyAppWeb.CounterLive do
  use Lavash.LiveView.Explicit

  reactive do
    state :count, 0
    state :step, 1
    derive :doubled, rx(@count * @step)
  end

  @impl Phoenix.LiveView
  def handle_event("inc", _, socket) do
    {:noreply, put_state(socket, :count, &(&1 + 1))}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <p>{@count} (doubled = {@doubled})</p>
    <button phx-click="inc">+</button>
    """
  end
end
```

`put_state/3` mutates a field and immediately recomputes the dependent
graph — no "I forgot to call recompute" footgun. `mount/3` and
`handle_info/2` for async derives are wired automatically.

This path is useful when you want the reactive primitives but don't need
the DSL's optimistic JS, URL-backed state, forms, or overlays. If you
want the DSL but still no client-side optimism, use
`Lavash.LiveView.Base` instead (layers 1 + 2 + 3).
