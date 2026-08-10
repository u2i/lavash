# Layer 1: Base DSL

The DSL surface that maps to vanilla Phoenix.LiveView constructs. Compile-
time validation, no state machinery beyond what Phoenix gives you. This
layer covers actions, the template block, components, and the lifecycle
blocks (`mount`, `messages`, `async`, `when_connected`, `on_mount`).

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
| `effect fn` | Execute side effects |
| `run fn` | Run a function over `socket` (full LV API available) |
| `submit :form` | Submit a form |
| `navigate path` | Navigate to URL |
| `push_patch to: path` | Patch the URL without remount |
| `redirect to: path` | Hard redirect |
| `push_event "name", payload` | Dispatch a JS event to the page |
| `flash :level, msg` | Show flash message |
| `fire :name` | Trigger an `async :name do ... end` declaration |
| `invoke id, :action` | Invoke an action on a child component |

`set :field, rx(...)` transpiles to JS for optimistic updates (layer 4).
`effect`, `submit`, `run`, `push_patch`, `redirect`,
`push_event`, `flash`, `fire`, `invoke` always go through the server.

## Templates and auto-injection

Lavash modules declare their template with a `template do ~H"..."end`
block. The transformer rewrites the template at compile time, injecting:

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
(non-bare expressions, `unless`, complex class concatenation, etc.). Most
of the auto-injected attributes are layer-4 concerns — they only fire on
fields marked `optimistic: true` — but the template transformer itself
is a layer-1 piece of compile-time plumbing.

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

  template do
    ~H"""
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

## Lifecycle blocks

Beyond actions (which respond to events), lavash also has declarative
blocks for the LiveView callback surface.

### `messages do message :name do ... end end`

`handle_info` as op-sequence — the same vocabulary as actions
(`run`/`effect`/`set`/`fire`). For PubSub broadcasts, self-scheduled
timers, monitor messages:

```elixir
messages do
  message :tick do
    set :ticks, rx(@ticks + 1)
  end

  message {:user_event, payload}, [:payload] do
    run fn socket ->
      assign(socket, :last_event, payload)
    end
  end
end
```

### `async :name do run fn end end`

Declares a triggerable async task — like vanilla LV's `assign_async`
but invoked explicitly via `fire :name`:

```elixir
async :report do
  run fn assigns ->
    {:ok, generate_report(assigns.filters)}
  end
end

actions do
  action :refresh do
    fire :report
  end
end
```

The field lands as `%Phoenix.LiveView.AsyncResult{}` on assigns,
playable in `case @report do %AsyncResult{...}` patterns.

### `mount do <ops> end`

Op-sequence for mount-time setup. Symmetric with `messages do`:

```elixir
mount do
  fire :report

  when_connected do
    run fn socket ->
      Phoenix.PubSub.subscribe(MyApp.PubSub, "updates")
      Process.send_after(self(), :tick, 1000)
      socket
    end
  end
end
```

`when_connected do ... end` is a guard for ops that should only run on
the websocket mount (not the initial HTTP render) — replaces the
ubiquitous `if connected?(socket) do ... end` pattern.
