# Lavash

Declarative, reactive state for Phoenix LiveView. Lavash is two things in one
package:

- a **DSL** (`use Lavash.LiveView` / `use Lavash.Component`) that declares
  state, computed values, actions, forms, and components, and a `~L` template
  sigil that auto-injects the client-side machinery for optimistic updates.
- a **reactive engine** (`Lavash.Reactive` / `use Lavash.LiveView.Explicit`)
  that works without the DSL — you write a plain `Phoenix.LiveView` and use
  the dependency graph directly.

Either way, the reactive graph runs on the server: declared values recompute
in topological order when their dependencies change, and the optimistic JS
hook keeps the rendered DOM in sync without a server round-trip for changes
that can be transpiled.

## Why Lavash?

- **Reactive state**, not manual recompute. Declare a `calculate :doubled,
  rx(@count * 2)`; lavash recomputes it whenever its dependencies change.
- **Optimistic UI by default**. The `~L` sigil auto-injects `data-lavash-*`
  attributes so simple actions feel instant — the JS hook updates the DOM
  before the server reply lands.
- **URL-backed state**. `state :search, :string, from: :url` makes the
  field part of the URL — deep-linkable, refresh-safe, bookmarkable.
- **First-class Ash integration**. Read resources, submit forms, and
  auto-invalidate via PubSub on resource mutations.
- **Stateful components**. Lavash components have their own state, derived
  fields, and actions — and can bind to parent state.

## Installation

```elixir
def deps do
  [
    {:lavash, "~> 0.2"}
  ]
end
```

Configure PubSub for cross-process invalidation:

```elixir
# config/config.exs
config :lavash, pubsub: MyApp.PubSub
```

## Quick start

```elixir
defmodule MyAppWeb.CounterLive do
  use Lavash.LiveView

  state :count, :integer, from: :url, default: 0, optimistic: true
  state :multiplier, :integer, from: :ephemeral, default: 2, optimistic: true

  calculate :doubled, rx(@count * @multiplier)

  actions do
    action :increment do
      set :count, rx(@count + 1)
    end

    action :reset do
      set :count, 0
    end
  end

  render fn assigns ->
    ~L"""
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

Bare `{@count}` is wrapped in `<span data-lavash-display="count">` at compile
time. When the user clicks `+`, the JS hook updates the span text
instantly; the server reply arrives later and reconciles.

### Custom `mount/3`

Lavash generates a `mount/3` that initialises the reactive graph (state
hydration, dependency graph, PubSub subscriptions). The generated `mount/3`
is `defoverridable`, so you can define your own when you need extra per-route
setup — just chain into `Lavash.LiveView.Runtime.mount/4` first so the
reactive graph gets attached to the socket:

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

To enable the JS hook in `app.js`:

```javascript
import { LavashOptimistic } from "lavash";

let liveSocket = new LiveSocket("/live", Socket, {
  hooks: { LavashOptimistic, ...otherHooks }
});
```

## State

Lavash supports three persistence modes:

| `from:` | Persisted in | Survives refresh | Survives reconnect | Shareable |
|---|---|---|---|---|
| `:url` | Query string | Yes | Yes | Yes |
| `:socket` | JS client | No | Yes | No |
| `:ephemeral` (default) | Process only | No | No | No |

```elixir
# URL-backed: filters, pagination, tabs
state :search, :string, from: :url, default: ""
state :page, :integer, from: :url, default: 1

# Socket-backed: UI state that survives reconnects
state :expanded_ids, {:array, :uuid}, from: :socket, default: []

# Ephemeral: temporary
state :hovering, :boolean, default: false
```

### Optimistic state

Add `optimistic: true` to make a field part of the client-side state map. The
`LavashOptimistic` JS hook reads it from `data-lavash-state` and updates the
DOM as transpiled actions fire — before the server reply arrives.

```elixir
state :count, :integer, default: 0, optimistic: true
```

Without `optimistic: true`, the field still works server-side but every
update takes a full LiveView round-trip.

### Auto-generated setters

`setter: true` generates a `set_<name>` action callable from the client (e.g.
from a form input's `phx-change`):

```elixir
state :search, :string, from: :url, default: "", setter: true
# Generates: action :set_search, [:value] do set :search, rx(@value) end
```

## Type system

Built-in types with automatic URL serialization:

- `:string` — pass-through
- `:integer` — `"42"` ↔ `42`
- `:float` — `"3.14"` ↔ `3.14`
- `:boolean` — `"true"` ↔ `true`
- `:uuid` — full UUID ↔ base32 (26 chars)
- `{:uuid, "prefix"}` — TypeID format (`cat_01h455vb4pex5vsknk084sn02q`)
- `:atom` — uses `String.to_existing_atom/1`
- `{:array, type}` — `"a,b,c"` ↔ `["a", "b", "c"]`

### Custom types

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

state :start_date, MyApp.Types.Date, from: :url
```

## Reactive expressions: `rx`

`rx(...)` captures an expression at compile time. References to `@field` are
tracked as dependencies. The same expression compiles to both Elixir (for
server-side evaluation) and JavaScript (for the optimistic hook).

```elixir
calculate :doubled, rx(@count * 2)
calculate :total, rx(Enum.sum(@items))
calculate :greeting, rx("Hi, " <> @name)
```

### Async calculations

`async: true` runs the computation in a background task. The field is set to
`AsyncResult.loading()` immediately and updated when the task completes.
Downstream calculations propagate loading/failed states automatically.

```elixir
calculate :report, rx(generate_report(@filters)), async: true
calculate :report_size, rx(byte_size(@report))  # waits for :report
```

In templates, async fields are `%Phoenix.LiveView.AsyncResult{}`:

```elixir
<%= case @report do %>
  <% %AsyncResult{loading: true} -> %>Loading...
  <% %AsyncResult{ok?: true, result: data} -> %>{inspect(data)}
  <% _ -> %>Error
<% end %>
```

### Importing reactive helpers

`defrx` declares a transpilable helper; `import_rx` makes it available in
`rx()` blocks elsewhere:

```elixir
defmodule MyApp.Validators do
  use Lavash.Rx.Functions

  defrx valid_email?(email) do
    String.length(email) > 0 && String.contains?(email, "@")
  end
end

defmodule MyAppWeb.SignupLive do
  use Lavash.LiveView
  import_rx MyApp.Validators

  calculate :email_valid, rx(valid_email?(@email))
end
```

## Reading Ash resources

### Get by ID

```elixir
read :product, Product do
  id state(:product_id)
  async true  # default
end
```

### Query with auto-mapped arguments

```elixir
read :products, Product, :list do
  invalidate :pubsub  # fine-grained PubSub invalidation
end
# Auto-maps state fields to action arguments by name
```

### As dropdown options

```elixir
read :categories, Category do
  async false
  as_options label: :name, value: :id
end
```

## Forms

Auto-detects create vs. update based on data:

```elixir
form :edit_form, Product do
  data result(:product)  # nil → create, record → update
end

# Params are auto-created as :edit_form_params (ephemeral state).
# Validation derives are auto-generated: :edit_form_<field>_valid,
# :edit_form_<field>_errors, :edit_form_valid, :edit_form_errors.
```

Hook a form into your template:

```elixir
<form phx-change="form_change_edit_form" phx-submit="save">
  <input field={@edit_form[:name]} />
  <input field={@edit_form[:price]} />
  <button type="submit" disabled={not @edit_form_valid}>Save</button>
</form>
```

`<input field={...}>` auto-injects `name`, `value`, and the right
`data-lavash-*` attrs so validation errors render instantly client-side.

## Actions

Declarative event handlers triggered by `phx-click`, `phx-change`, etc.

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

  # Guarded — only fires when @form_valid is true
  action :submit, [], [:form_valid] do
    submit :form
  end
end
```

### Action operations

| Operation | Description |
|---|---|
| `set :field, rx(...)` | Set field via a reactive expression (transpilable) |
| `set :field, value` | Set field to a literal value |
| `update :field, fun` | Transform field with a function (server-only) |
| `effect fn` | Execute side effects |
| `submit :form` | Submit a form |
| `navigate path` | Navigate to URL |
| `flash :level, msg` | Show flash message |
| `invoke id, :action` | Invoke an action on a child component |

`set :field, rx(...)` transpiles to JS for optimistic updates. `update`,
`effect`, `submit`, etc. always go through the server.

## The `~L` sigil and auto-injection

Use `~L` (not `~H`) in render functions inside Lavash modules. The
transformer rewrites the template at compile time, injecting:

| You write | Becomes |
|---|---|
| `{@count}` (optimistic) | `<span data-lavash-display="count">{@count}</span>` |
| `<input field={@form[:name]}>` | Phoenix form attrs + `data-lavash-bind` + error attrs |
| `<div :if={@open}>` (optimistic) | adds `data-lavash-visible="open"` |
| `<button disabled={not @valid}>` (optimistic) | adds `data-lavash-enabled="valid"` |
| `<div class={if @flag, do: "on", else: "off"}>` (optimistic) | adds `data-lavash-toggle="flag\|on\|off"` |
| `<div class={if "x" in @items, do: "sel", else: "unsel"}>` (optimistic) | adds `data-lavash-member="items\|sel\|unsel"` + `data-lavash-member-value="x"` |
| `<.lavash_component module=Child id="x" bind={[n: :count]}>` | adds parent value forwarding + binding-chain plumbing |

You write normal Phoenix HEEx; lavash adds the wiring underneath. Hand-written
`data-lavash-*` attributes still work for cases the inference can't reach
(non-bare expressions, `unless`, complex class concatenation, etc.).

### Diagnostics

The transformer warns at compile time when:

- A bare `{@field}` references a declared-but-non-optimistic state field —
  the template renders as plain text. Likely missing `optimistic: true`.
- `<.lavash_component bind=[child: :parent]>` targets a `:parent` that isn't a
  declared state field on the host — the binding is write-only and the
  child won't receive parent updates.

## Components

```elixir
defmodule MyAppWeb.ProductCard do
  use Lavash.Component

  prop :product, :map, required: true

  state :expanded, :boolean, from: :socket, default: false, optimistic: true

  calculate :title, rx(@product.name)

  actions do
    action :toggle do
      set :expanded, rx(not @expanded)
    end
  end

  render fn assigns ->
    ~L"""
    <div phx-click="toggle">
      <h3>{@title}</h3>
      <div :if={@expanded}>Details...</div>
    </div>
    """
  end
end
```

`phx-target={@myself}` is auto-injected inside component templates — you
don't have to type it on every `phx-*` attribute.

### Using a component

```elixir
import Lavash.LiveView.Helpers, only: [lavash_component: 1]

<.lavash_component
  module={MyAppWeb.ProductCard}
  id={"product-#{product.id}"}
  product={product}
/>
```

### Bindings

A child can declare a `bind=` mapping to read and write a parent's state
field:

```elixir
<.lavash_component
  module={MyAppWeb.Toggle}
  id="dark-mode"
  bind={[value: :dark_mode]}
/>
```

The child's `:value` field hydrates from the parent's `:dark_mode` on every
update; the child's writes to `:value` propagate back up to the parent's
`:dark_mode`. Works across arbitrarily nested chains via parent CID routing
or `send_update`.

### Invoking component actions from parent

```elixir
actions do
  action :open_modal, [:id] do
    invoke "product-modal", :open,
      module: MyAppWeb.ProductModal,
      params: [product_id: {:param, :id}]
  end
end
```

## Overlays (modals, flyovers)

Pre-built phase-machine driven overlay behavior:

```elixir
defmodule MyAppWeb.ProductModal do
  use Lavash.Component, extensions: [Lavash.Overlay.Modal.Dsl]
  import Lavash.Overlay.Modal.Helpers

  modal do
    open_field :product_id  # nil = closed
    close_on_escape true
    close_on_backdrop true
    async_assign :edit_form
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

  render fn assigns ->
    ~L"""
    <div class="p-6">
      <.modal_close_button myself={@myself} />
      <!-- form content -->
    </div>
    """
  end
end
```

The overlay runs through phases (`idle → entering → [loading] → visible →
exiting → idle`); the optimistic JS hook drives the transitions
client-side.

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

`Lavash.LiveView.Explicit` exposes the reactive engine without the Spark
DSL, the `~L` transformer, the optimistic JS, or any of the overlay /
form / binding machinery. You get the dependency graph and automatic
recomputation; you write `mount/3`, `handle_event/3`, and `render/1` like
any plain Phoenix LiveView.

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
the DSL's optimistic JS, URL-backed state, forms, or overlays.

## License

MIT
