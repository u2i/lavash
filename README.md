# Lavash

Declarative state management for Phoenix LiveView, built for Ash Framework.

## Why Lavash?

**Solve LiveView's state loss problem.** Standard LiveView stores all state server-side, which means network disconnects, deploys, or server restarts lose user state. Lavash solves this by treating the client as the source of truth:

- **URL state** survives refresh, is shareable, and enables deep linking
- **Socket state** syncs to JS and survives reconnects (but not refresh)
- **Ephemeral state** for temporary UI state that can be lost

**Components that own their state.** Unlike standard LiveComponents which are stateless renderers, Lavash components can declare and manage their own state, derived fields, forms, and actions—just like LiveViews.

**First-class Ash integration.** Read Ash resources with auto-mapped action arguments, submit forms that auto-detect create vs update, and get cross-process PubSub invalidation when resources mutate.

## Features

- **Client-Driven State** - URL and socket state survive disconnects; no more lost form data
- **Stateful Components** - Components with their own state, derives, forms, and actions
- **Ash Integration** - Read resources, submit forms, auto-invalidate on mutations
- **Derived Fields** - Computed values with dependency tracking and async support
- **Declarative Actions** - Event handlers with set, update, submit, navigate, flash
- **PubSub Invalidation** - Fine-grained cross-process cache invalidation
- **Type System** - Automatic URL serialization with custom type support
- **Optimistic Updates** - Instant client-side state changes with automatic server reconciliation
- **Modal Plugin** - Ready-to-use modal behavior for components

## Installation

```elixir
def deps do
  [
    {:lavash, "~> 0.1.0"}
  ]
end
```

Configure PubSub for cross-process invalidation:

```elixir
# config/config.exs
config :lavash, pubsub: MyApp.PubSub
```

## Quick Start

```elixir
defmodule MyAppWeb.CounterLive do
  use Lavash.LiveView

  # URL state - survives refresh, shareable
  state :count, :integer, from: :url, default: 0

  # Computed value - updates when count changes
  derive :doubled do
    argument :count, state(:count)
    run fn %{count: c}, _ -> c * 2 end
  end

  # Actions transform state
  actions do
    action :increment do
      update :count, &(&1 + 1)
    end

    action :reset do
      set :count, 0
    end
  end

  def render(assigns) do
    ~H"""
    <div>
      <p>Count: {@count}</p>
      <p>Doubled: {@doubled}</p>
      <button phx-click="increment">+</button>
      <button phx-click="reset">Reset</button>
    </div>
    """
  end
end
```

## State Types

Lavash provides three state persistence modes:

| Type | Persisted In | Survives Refresh | Survives Reconnect | Shareable |
|------|--------------|------------------|-------------------|-----------|
| `:url` | Query string | Yes | Yes | Yes |
| `:socket` | JS client | No | Yes | No |
| `:ephemeral` | Process only | No | No | No |

```elixir
# URL state - filters, pagination, tabs
state :search, :string, from: :url, default: ""
state :page, :integer, from: :url, default: 1

# Socket state - UI state that survives reconnects
state :expanded_ids, {:array, :uuid}, from: :socket, default: []

# Ephemeral state - temporary, fastest
state :hovering, :boolean, from: :ephemeral, default: false
```

### Auto-Generated Setters

Use `setter: true` to auto-generate a `set_<name>` action:

```elixir
state :search, :string, from: :url, default: "", setter: true
# Generates: action :set_search, [:value] do set :search, &(&1.params.value) end
```

## Type System

Built-in types with automatic URL serialization:

- `:string` - Pass-through
- `:integer` - `"42"` <-> `42`
- `:float` - `"3.14"` <-> `3.14`
- `:boolean` - `"true"` <-> `true`
- `:uuid` - Full UUID <-> base32 (26 chars)
- `{:uuid, "prefix"}` - TypeID format: `cat_01h455vb4pex5vsknk084sn02q`
- `:atom` - Uses `String.to_existing_atom/1`
- `{:array, type}` - `"a,b,c"` <-> `["a", "b", "c"]`

### Custom Types

```elixir
defmodule MyApp.Types.Date do
  use Lavash.Type

  @impl true
  def parse(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, "invalid date"}
    end
  end

  @impl true
  def dump(%Date{} = date), do: Date.to_iso8601(date)
end

# Usage
state :start_date, MyApp.Types.Date, from: :url
```

## Derived Fields

Computed values with automatic dependency tracking:

```elixir
derive :total do
  argument :items, state(:items)
  argument :tax_rate, state(:tax_rate)

  run fn %{items: items, tax_rate: rate}, _ ->
    subtotal = Enum.sum(Enum.map(items, & &1.price))
    subtotal * (1 + rate)
  end
end
```

### Async Derived Fields

For expensive computations:

```elixir
derive :report do
  async true
  argument :filters, state(:filters)

  run fn %{filters: f}, _ ->
    # Expensive computation
    generate_report(f)
  end
end
```

In templates, async fields render as `%Phoenix.LiveView.AsyncResult{}`:

```elixir
<%= case @report do %>
  <% %AsyncResult{loading: true} -> %>Loading...
  <% %AsyncResult{ok?: true, result: data} -> %>{inspect(data)}
  <% _ -> %>Error
<% end %>
```

### Chained Derived Fields

Derived fields can depend on other derived fields:

```elixir
derive :doubled do
  argument :count, state(:count)
  run fn %{count: c}, _ -> c * 2 end
end

derive :quadrupled do
  argument :doubled, result(:doubled)
  run fn %{doubled: d}, _ -> d * 2 end
end
```

## Reading Ash Resources

### Get by ID

```elixir
read :product, Product do
  id state(:product_id)
  async true  # default
end
```

### Query with Auto-Mapped Arguments

```elixir
read :products, Product, :list do
  invalidate :pubsub  # Enable fine-grained PubSub invalidation
end
# Auto-maps state fields to action arguments by name
```

### As Dropdown Options

```elixir
read :categories, Category do
  async false
  as_options label: :name, value: :id
end
```

## Forms

Auto-detects create vs update based on data:

```elixir
form :edit_form, Product do
  data result(:product)  # nil = create, record = update
end

# Params auto-created as :edit_form_params ephemeral state
```

## Actions

Declarative event handlers:

```elixir
actions do
  action :save do
    submit :edit_form, on_success: :after_save, on_error: :on_error
  end

  action :after_save do
    flash :info, "Saved!"
    navigate "/products"
  end

  action :on_error do
    flash :error, "Failed to save"
  end

  # With parameters from phx-value-*
  action :delete, [:id] do
    effect fn %{params: %{id: id}} ->
      Product |> Ash.get!(id) |> Ash.destroy!()
    end
  end

  # Guarded actions
  action :submit, [], [:form_valid] do
    submit :form
  end
end
```

### Action Operations

| Operation | Description |
|-----------|-------------|
| `set :field, value` | Set field to value or function |
| `update :field, fn` | Transform field with function |
| `effect fn` | Execute side effects |
| `submit :form` | Submit a form |
| `navigate path` | Navigate to URL |
| `flash :level, msg` | Show flash message |
| `invoke id, :action` | Invoke action on child component |

## Components

LiveComponents with props:

```elixir
defmodule MyAppWeb.ProductCard do
  use Lavash.Component

  prop :product, :map, required: true
  prop :on_select, :atom  # Event name for notify_parent

  state :expanded, :boolean, from: :socket, default: false

  derive :title do
    argument :product, prop(:product)
    run fn %{product: p}, _ -> p.name end
  end

  actions do
    action :toggle do
      update :expanded, &(!&1)
    end

    action :select do
      notify_parent :on_select
    end
  end

  def render(assigns) do
    ~H"""
    <div phx-click="toggle" phx-target={@myself}>
      <h3>{@title}</h3>
      <div :if={@expanded}>Details...</div>
      <button phx-click="select" phx-target={@myself}>Select</button>
    </div>
    """
  end
end
```

Usage with `lavash_component`:

```elixir
import Lavash.LiveView.Helpers

<.lavash_component
  module={MyAppWeb.ProductCard}
  id={"product-#{product.id}"}
  product={product}
  on_select="product_selected"
/>
```

### Invoking Component Actions from Parent

```elixir
# In parent LiveView
actions do
  action :open_modal, [:id] do
    invoke "product-modal", :open,
      module: MyAppWeb.ProductModal,
      params: [product_id: {:param, :id}]
  end
end
```

## Modal Plugin

Pre-built modal behavior:

```elixir
defmodule MyAppWeb.ProductModal do
  use Lavash.Component, extensions: [Lavash.Modal.Dsl]
  import Lavash.Modal.Helpers

  modal do
    open_field :product_id  # nil = closed
    close_on_escape true
    close_on_backdrop true
    async_assign :edit_form
  end

  render_loading fn assigns ->
    ~H"<div class=\"p-6\">Loading...</div>"
  end

  render fn assigns ->
    ~H"""
    <div class="p-6">
      <.modal_close_button myself={@myself} />
      <!-- Form content -->
    </div>
    """
  end

  read :product, Product do
    id state(:product_id)
  end

  form :edit_form, Product do
    data result(:product)
  end

  actions do
    action :save do
      submit :edit_form, on_success: :close
    end
  end
end
```

## Optimistic Updates

Make UI feel instant by applying state changes client-side before server confirmation. Lavash automatically generates JavaScript functions from your DSL declarations.

### Basic Setup

1. Mark state fields and derives with `optimistic: true`:

```elixir
defmodule MyAppWeb.CounterLive do
  use Lavash.LiveView

  state :count, :integer, from: :url, default: 0, optimistic: true
  state :multiplier, :integer, from: :ephemeral, default: 2, optimistic: true

  derive :doubled do
    optimistic true
    argument :count, state(:count)
    argument :multiplier, state(:multiplier)
    run fn %{count: c, multiplier: m}, _ -> c * m end
  end

  actions do
    action :increment do
      update :count, &(&1 + 1)
    end

    action :decrement do
      update :count, &(&1 - 1)
    end
  end
end
```

2. Add `data-optimistic` to trigger elements and use the `<.o>` helper for display elements:

```elixir
import Lavash.LiveView.Helpers

def render(assigns) do
  ~H"""
  <div>
    <.o field={:count} value={@count} tag="div" />
    <.o field={:doubled} value={@doubled} />

    <button phx-click="increment" data-optimistic="increment">+</button>
    <button phx-click="decrement" data-optimistic="decrement">-</button>
  </div>
  """
end
```

The `<.o>` component eliminates duplication by generating both the display and the `data-optimistic-display` attribute. It supports:
- `field` - the state/derive field name (required)
- `value` - the current value from assigns (required)
- `tag` - HTML tag to use (default: "span")
- Additional HTML attributes like `class`

Alternatively, you can use the raw data attribute:

```elixir
<div data-optimistic-display="count">{@count}</div>
```

3. Register the hook in your `app.js`:

```javascript
import { LavashOptimistic } from "./lavash_optimistic";

let liveSocket = new LiveSocket("/live", Socket, {
  hooks: { LavashOptimistic, ...otherHooks }
});
```

### How It Works

When a user clicks a button with `data-optimistic="increment"`:

1. **Client-side**: The hook immediately runs the generated JavaScript function to update state
2. **Server-side**: The normal `phx-click` event is sent to the server
3. **Reconciliation**: When the server responds, stale values are ignored using per-field tracking

Actions are automatically converted to JavaScript if they only contain `set` and `update` operations:

| Elixir DSL | Generated JavaScript |
|------------|---------------------|
| `update :count, &(&1 + 1)` | `count: state.count + 1` |
| `update :count, &(&1 - 1)` | `count: state.count - 1` |
| `set :count, 0` | `count: 0` |
| `set :count, &String.to_integer(&1.params.value)` | `count: Number(value)` |

### Custom Derive Functions

For complex derived values, provide JavaScript implementations via ColocatedJS:

```elixir
<script :type={Phoenix.LiveView.ColocatedJS} name="optimistic">
  function factorial(n) {
    if (n < 0) return null;
    if (n > 170) return Infinity;
    let result = 1;
    for (let i = 2; i <= n; i++) result *= i;
    return result;
  }

  export default {
    // Derive functions receive state and return the computed value
    doubled(state) {
      return state.count * state.multiplier;
    },

    fact(state) {
      return factorial(Math.max(state.count, 0));
    }
  };
</script>
```

Register custom functions in `app.js`:

```javascript
import optimistic from "phoenix-colocated/demo/DemoWeb.CounterLive/optimistic";
window.Lavash = window.Lavash || {};
window.Lavash.optimistic = window.Lavash.optimistic || {};
window.Lavash.optimistic["DemoWeb.CounterLive"] = optimistic;
```

### Input Fields

For range sliders and other inputs, use `data-optimistic-field`:

```elixir
<input
  type="range"
  name="value"
  value={@multiplier}
  phx-change="set_multiplier"
  data-optimistic-field="multiplier"
/>
```

### Actions with Parameters

For actions that take values (like "Set to 100"), use `data-optimistic-value`:

```elixir
<button
  phx-click="set_count"
  phx-value-amount="100"
  data-optimistic="set_count"
  data-optimistic-value="100"
>
  Set to 100
</button>
```

### Limitations

Optimistic updates work best for:
- Simple numeric operations (increment, decrement, set)
- Pure computed values (derives)
- UI state that doesn't require server validation

Actions with side effects (`submit`, `navigate`, `effect`, `invoke`) are not generated as optimistic functions.

## PubSub Invalidation

Cross-process resource invalidation for multi-tab/user scenarios:

```elixir
# In read declaration
read :products, Product, :list do
  invalidate :pubsub
end

# In Ash resource - specify which attributes trigger invalidation
defmodule MyApp.Product do
  use Ash.Resource, extensions: [Lavash.Resource]

  lavash do
    notify_on [:category_id, :in_stock]
  end
end
```

When a form submits, Lavash broadcasts to all relevant PubSub topics, and LiveViews with matching reads automatically reload.

## Architecture

Lavash stores all state in `socket.private.lavash` to avoid LiveView change tracking overhead:

```
socket.private.lavash = %{
  state: %{},      # Current state values
  derived: %{},    # Computed values
  dirty: MapSet,   # Fields needing recomputation
  url_fields: MapSet,
  socket_fields: MapSet
}
```

The dependency graph ensures derived fields compute in topological order, and only dirty fields are recomputed on state changes.

## License

MIT
