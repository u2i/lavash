# Lavash

Declarative state, reactivity, and optimistic UI for Phoenix LiveView. Lavash
is a Spark DSL on top of `Phoenix.LiveView` that turns the usual grab-bag of
assigns, `handle_event` clauses, `handle_info` callbacks, and hand-written
JS hooks into a small set of declarative entities — state fields,
reactive expressions, actions, components, forms — that the compiler
cross-validates and (where applicable) transpiles to client-side JS for
optimistic updates. The reactive graph is always server-authoritative;
the optimistic layer is a UX shim that runs in front of it.

## Architecture: the four layers

Lavash is best understood as four stacked concerns. Each layer has a
self-contained value proposition and can be consumed without the layers
above it.

1. **Base** — the Spark DSL surface (`mount`, `actions`, `messages`,
   `async`, `when_connected`, `template`, components, slots, `on_mount`)
   wired straight onto Phoenix LiveView. Compile-time validation of
   `phx-click` event names against declared actions, of `phx-value-*`
   params against declared action args, of `@field` references against
   declared state. No state machinery beyond what Phoenix gives you.
2. **State** — declarative persistence and sync: `state :foo, from:
   :url | :socket | :session | :assigns | :ephemeral`.
   `Lavash.Socket.put_state/3` is the single write path; hydration is
   handled at mount. A flat `lavashState` object lives on the JS client
   so socket-backed state survives reconnects.
3. **Rx** — server-side reactive graph. `calculate :foo, rx(...)` and
   `rx(...)` inside action bodies are the two surface forms. The
   compiler builds a topologically ordered dependency graph and
   recomputes only affected derives on every state change. Async
   derives (`async: true`) are supported. All eval is server-side;
   results flow through normal LiveView diffs.
4. **Optimism** — client-side instant feedback. `optimistic: true` on
   state and calculations causes the rx transpiler to emit JS, the
   template transformer to auto-inject `data-lavash-*` annotations
   (display, toggle, member, visible, enabled), and the
   `LavashOptimistic` JS hook to mount a per-hook reactive store
   (SyncedVar + merge walker) that reconciles client predictions with
   the server's authoritative reply. `animated: ...` adds the
   `idle/entering/visible/exiting` phase machine used by modals and
   flyovers.

The full stack is `use Lavash.LiveView` / `use Lavash.Component`. If you
want the DSL and the reactive graph without the optimistic UI layer,
`use Lavash.LiveView.Base` / `use Lavash.Component.Base` opt out
explicitly — `optimistic: true` and `animated:` become compile-time
errors, so "no client-side optimism" is a load-bearing contract the
schema enforces. The point isn't bundle size (layer 4 is already
pay-for-what-you-use under the full DSL — if no field is marked
`optimistic: true`, the optimistic transformers no-op); it's having
explicit contracts you can write code against.

For the deep treatment of layer boundaries, back-edges, and the
file-by-file inventory, see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Why Lavash?

- **Declarative actions** (layer 1). `phx-click="increment"` resolves
  against an `action :increment do ... end` block; the compiler cross-
  validates event names, params, and assign references. Op-sequence
  vocabulary (`set`, `run`, `effect`, `submit`, `navigate`, `fire`,
  `flash`, `push_event`, `push_patch`, `redirect`) replaces the usual
  scattered `handle_event` clauses.
- **URL-backed state** (layer 2). `state :search, :string, from: :url`
  makes the field part of the URL — deep-linkable, refresh-safe,
  bookmarkable. `:socket`, `:session`, `:assigns`, and `:ephemeral`
  sources cover the rest.
- **Reactive state**, not manual recompute (layer 3). Declare
  `calculate :doubled, rx(@count * 2)`; lavash recomputes it whenever
  its dependencies change, in topological order.
- **First-class Ash integration** (layer 3). Read resources, submit
  forms, and auto-invalidate via PubSub on resource mutations.
- **Optimistic UI by default** (layer 4). The template auto-injects
  `data-lavash-*` attributes so simple actions feel instant — the JS
  hook updates the DOM before the server reply lands.
- **Stateful components** (all layers). Lavash components have their
  own state, derived fields, and actions — and can bind to parent
  state via the `bind=` parent/child propagation chain.

## Installation

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

## Quick start

The same counter, evolved one layer at a time. Each step adds one
capability and shows what tradeoff it brings.

### Just the DSL (layer 1)

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

### Add declarative state (layer 2)

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

### Add reactivity (layer 3)

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

### Add optimistic UI (layer 4)

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

### Custom `mount/3`

Lavash generates a `mount/3` that initialises the reactive graph (state
hydration, dependency graph, PubSub subscriptions). For most mount-time
setup — firing async tasks, subscribing to PubSub, scheduling timers —
the declarative `mount do ... end` block (see
[Lifecycle blocks](#lifecycle-blocks)) is the better fit; it runs after
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

---

## Layer 1: Base DSL

The DSL surface that maps to vanilla Phoenix.LiveView constructs. Compile-
time validation, no state machinery beyond what Phoenix gives you. This
layer covers actions, the template block, components, and the lifecycle
blocks (`mount`, `messages`, `async`, `when_connected`, `on_mount`).

### Actions

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

#### Action operations

| Operation | Description |
|---|---|
| `set :field, rx(...)` | Set field via a reactive expression (transpilable) |
| `set :field, value` | Set field to a literal value |
| `update :field, fun` | Transform field with a function (server-only) |
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
`update`, `effect`, `submit`, `run`, `push_patch`, `redirect`,
`push_event`, `flash`, `fire`, `invoke` always go through the server.

### Templates and auto-injection

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

#### Diagnostics

The transformer warns at compile time when:

- A bare `{@field}` references a declared-but-non-optimistic state field —
  the template renders as plain text. Likely missing `optimistic: true`.
- `<.lavash_component bind=[child: :parent]>` targets a `:parent` that isn't a
  declared state field on the host — the binding is write-only and the
  child won't receive parent updates.

### Components

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

#### Using a component

```elixir
import Lavash.LiveView.Helpers, only: [lavash_component: 1]

<.lavash_component
  module={MyAppWeb.ProductCard}
  id={"product-#{product.id}"}
  product={product}
/>
```

#### Bindings

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

#### Invoking component actions from parent

```elixir
actions do
  action :open_modal, [:id] do
    invoke "product-modal", :open,
      module: MyAppWeb.ProductModal,
      params: [product_id: {:param, :id}]
  end
end
```

### Lifecycle blocks

Beyond actions (which respond to events), lavash also has declarative
blocks for the LiveView callback surface.

#### `messages do message :name do ... end end`

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

#### `async :name do run fn end end`

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

#### `mount do <ops> end`

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

---

## Layer 2: State management

Declarative persistence and sync. `state :foo, :type, from: ...` declares
where a piece of state comes from and where its mutations propagate to.
Server is always authoritative; the client carries a flat `lavashState`
object across reconnects.

### State

Lavash supports several persistence sources:

| `from:` | Persisted in | Survives refresh | Survives reconnect | Shareable |
|---|---|---|---|---|
| `:url` | Query string | Yes | Yes | Yes |
| `:socket` | JS client | No | Yes | No |
| `:session` | Phoenix session | Yes | Yes | No |
| `:assigns` | Existing assign | depends on source | depends on source | depends on source |
| `:ephemeral` (default) | Process only | No | No | No |

```elixir
# URL-backed: filters, pagination, tabs
state :search, :string, from: :url, default: ""
state :page, :integer, from: :url, default: 1

# Socket-backed: UI state that survives reconnects
state :expanded_ids, {:array, :uuid}, from: :socket, default: []

# Lift an on_mount-injected assign (e.g. @current_user from your auth
# plug) into lavash state so calculate/actions can see it.
state :user, :map, from: :assigns, assigns_key: :current_user

# Ephemeral: temporary
state :hovering, :boolean, default: false
```

`from: :url` looks up the query/path parameter under the field name by
default. If the URL key needs to differ — typically because the query
string uses a shorter name — set `url_name:`:

```elixir
# URL: /attest?subject=alice
state :subject_handle, :string, from: :url, default: nil, url_name: "subject"
```

When a `from: :url` field falls back to its default and there's no
matching key in the params (and the URL did have other params), Lavash
logs a dev-only warning so a mismatched `url_name` doesn't silently
hydrate to `nil`. Use `required: true` if missing the param should
raise instead.

### Auto-generated setters

`setter: true` generates a `set_<name>` action callable from the client (e.g.
from a form input's `phx-change`):

```elixir
state :search, :string, from: :url, default: "", setter: true
# Generates: action :set_search, [:value] do set :search, rx(@value) end
```

### Type system

Built-in types with automatic URL serialization:

- `:string` — pass-through
- `:integer` — `"42"` ↔ `42`
- `:float` — `"3.14"` ↔ `3.14`
- `:boolean` — `"true"` ↔ `true`
- `:uuid` — full UUID ↔ base32 (26 chars)
- `{:uuid, "prefix"}` — TypeID format (`cat_01h455vb4pex5vsknk084sn02q`)
- `:atom` — uses `String.to_existing_atom/1`
- `{:array, type}` — `"a,b,c"` ↔ `["a", "b", "c"]`

#### Custom types

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

---

## Layer 3: Reactive expressions

The server-side reactive graph engine. `calculate :foo, rx(...)` and
`rx(...)` inside action bodies (e.g. `set :count, rx(@count + 1)`) are
the two surface forms. The compiler builds a topologically ordered
dependency graph and recomputes only affected derives on every state
change.

### Reactive expressions: `rx`

`rx(...)` captures an expression at compile time. References to `@field` are
tracked as dependencies. The same expression compiles to both Elixir (for
server-side evaluation) and JavaScript (for the optimistic hook — layer 4).

```elixir
calculate :doubled, rx(@count * 2)
calculate :total, rx(Enum.sum(@items))
calculate :greeting, rx("Hi, " <> @name)
```

#### Async calculations

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

#### Importing reactive helpers

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

### Reading Ash resources

#### Get by ID

```elixir
read :product, Product do
  id state(:product_id)
  async true  # default
end
```

#### Query with auto-mapped arguments

```elixir
read :products, Product, :list do
  invalidate :pubsub  # fine-grained PubSub invalidation
end
# Auto-maps state fields to action arguments by name
```

#### As dropdown options

```elixir
read :categories, Category do
  async false
  as_options label: :name, value: :id
end
```

### Forms

Forms ride on the reactive graph: auto-generated `<form>_<field>_valid`
and `<form>_valid` calculations are derived from Ash constraints, so
the submit button can live-update from `rx(...)` instead of from
manual on-change handlers.

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

#### Forms vs. `data-lavash-bind` on submit

`data-lavash-bind` (the attribute the auto-injector adds to `<input
field={...}>`) syncs through Lavash's own channel events, not through
`phx-change`. The flow is async: typing into a bound input fires a
client-only optimistic update plus a debounced server push.

For inputs hooked up via `<input field={@form[...]}>` this is fine —
`phx-submit` re-reads `@form` from the AshPhoenix.Form params, which
are kept in dedicated ephemeral state (`<form_name>_params`).

For bound state on a hand-rolled form (`data-lavash-bind="confirmed"`
on a checkbox, etc.) submit can race the bind sync. If the user ticks
the box and immediately clicks submit, the `phx-submit` request can
arrive at the server before the bind has propagated, and the action
body sees the not-yet-synced value of `@confirmed`.

Two safe patterns until this gap closes:

- Prefer the `<.form for={@some_form}>` / `field={...}` flow for any
  submit-style interaction.
- For hand-rolled forms, read the form params directly inside the
  action body (via the action's `params [...]` list) instead of
  through `@field` — `phx-submit` always carries the live form values.
  ```elixir
  action :submit, [:confirmed, :notes] do
    run fn %{confirmed: confirmed, notes: notes} = assigns ->
      # use confirmed/notes from the submitted form, not @confirmed
      ...
    end
  end
  ```

A future release will sync bound state through the submit payload so
the `@field` read works on submit too.

### Cookbook: a full form-submission recipe

The pieces above — `state`, `calculate`, `actions`, custom `mount/3`,
`Lavash.Socket.put_state/3`, and `action ..., [:fields]` — chain together
on a real page. This recipe shows all of them in one module: an
attestation form behind sign-in, with a URL-backed subject, ephemeral
form state, a submit button that lights up when the form is ready, and a
side-effecting submit handler.

```elixir
defmodule MyAppWeb.AttestLive do
  use Lavash.LiveView

  on_mount {AshAuthentication.LiveView, :live_user_required}

  # URL-backed: /attest?subject=alice is deep-linkable and refresh-safe.
  # `url_name:` lets the public param stay short while the field name
  # stays descriptive.
  state :subject_handle, :string,
    from: :url,
    default: nil,
    url_name: "subject",
    required: true,
    optimistic: true

  # Ephemeral form state, bound to the inputs in the template so the
  # checkbox + textarea can drive optimistic UI without a round-trip
  # for every keystroke.
  state :confirmed, :boolean, default: false, optimistic: true
  state :notes, :string, default: "", optimistic: true

  # Set on success so the template can swap the form for a thank-you.
  state :submitted_at, :utc_datetime, default: nil, optimistic: true

  # Seeded from the signed-in user inside the custom mount below.
  state :actor_email, :string, default: nil

  calculate :ready_to_submit,
    rx(@confirmed and String.length(@notes) > 0 and is_nil(@submitted_at))

  actions do
    # `params [...]` makes the action read the submit payload directly
    # rather than `@confirmed` / `@notes`, so it sees the fresh values
    # even if the bind sync hasn't caught up yet.
    action :submit, [:confirmed, :notes] do
      run fn %{confirmed: confirmed, notes: notes} = assigns ->
        case record_attestation(assigns.actor_email, assigns.subject_handle, confirmed, notes) do
          {:ok, at} -> assign(assigns, :submitted_at, at)
          {:error, _} -> assigns
        end
      end
    end
  end

  def mount(params, session, socket) do
    # Attach the reactive graph first — handle_params/3 needs it.
    {:ok, socket} = Lavash.LiveView.Runtime.mount(__MODULE__, params, session, socket)

    # Hydrate Lavash-aware state from the assigns the auth on_mount put
    # on the socket. `put_state/3` (not `assign/3`) registers the field
    # with the reactive graph and tracks dirty/url changes.
    socket = Lavash.Socket.put_state(socket, :actor_email, socket.assigns.current_user.email)
    {:ok, socket}
  end

  template do
    ~H"""
    <div :if={is_nil(@submitted_at)}>
      <h1>Attest for {@subject_handle}</h1>
      <form phx-submit="submit">
        <label>
          <input type="checkbox" name="confirmed" data-lavash-bind="confirmed" />
          I confirm the statements above.
        </label>
        <textarea name="notes" data-lavash-bind="notes"></textarea>
        <button type="submit" disabled={not @ready_to_submit}>Submit</button>
      </form>
    </div>
    <p :if={not is_nil(@submitted_at)}>
      Recorded at <span data-lavash-display="submitted_at">{@submitted_at}</span>.
    </p>
    """
  end

  defp record_attestation(actor_email, subject, confirmed, notes) do
    # ...persist via Ash, audit log, etc.
    {:ok, DateTime.utc_now()}
  end
end
```

A few things to notice, because they're easy to miss:

- The custom `mount/3` chains into `Lavash.LiveView.Runtime.mount/4`
  before doing anything else. The generated mount is `defoverridable`
  (see [Custom `mount/3`](#custom-mount3)); if you skip the chain, the
  first `handle_params/3` raises `Reactive graph not found on socket`.
- `Lavash.Socket.put_state/3` — not `Phoenix.Component.assign/3` — is
  what you reach for when seeding Lavash state from inside a custom
  mount. It registers the field with the reactive graph and tracks
  url/socket changes, so downstream `calculate`s and PubSub
  invalidations see the value. (Action `run fn` bodies can also read
  raw socket assigns like `@current_user` directly, but lifting the
  value into Lavash state keeps the auth library's shape out of
  business logic and makes the field observable to the reactive graph.)
- `action :submit, [:confirmed, :notes]` reads the live form payload
  rather than `@confirmed` / `@notes`. See
  [Forms vs. `data-lavash-bind` on submit](#forms-vs-data-lavash-bind-on-submit)
  for why — `phx-submit` can otherwise race the bind sync.
- The `run fn` body calls the unqualified private helper
  `record_attestation/4` directly. Action bodies are hoisted into a
  generated function on the user's module, so local `defp`s, aliases,
  and imports resolve normally.
- `disabled={not @ready_to_submit}` is auto-rewritten to
  `data-lavash-enabled="ready_to_submit"` because the expression is the
  negation of a calculated optimistic field — the button enables
  client-side the moment `@confirmed` and `@notes` are populated.

---

## Layer 4: Optimistic UI

Client-side instant feedback. `optimistic: true` on a state field or
calculation causes the rx transpiler to emit JS, the template
transformer to auto-inject `data-lavash-*` annotations, and the
`LavashOptimistic` JS hook to apply predictions client-side before the
server reply arrives. Under the hood: a per-hook SyncedVar store with
version tracking and a merge walker that reconciles server pushes
against in-flight optimistic state. The server is still the source of
truth — strip this layer out (`use Lavash.LiveView.Base`) and the app
still works, just with a round-trip-latency feel.

### Optimistic state

Add `optimistic: true` to make a field part of the client-side state map. The
lavash JS pipeline reads it from `data-lavash-state` and updates the DOM as
transpiled actions fire — before the server reply arrives.

```elixir
state :count, :integer, default: 0, optimistic: true
```

Without `optimistic: true`, the field still works server-side but every
update takes a full LiveView round-trip.

### Auto-injected DOM annotations

The layer-4 reach into HEEx is the family of `data-lavash-*` attributes
the template transformer adds when an expression resolves against an
optimistic field. You don't write them by hand for the common cases:

- `data-lavash-display="field"` — wraps bare `{@field}` in a span the
  hook can re-text directly.
- `data-lavash-toggle="field|on|off"` — toggles class strings based on
  a boolean optimistic field.
- `data-lavash-member="field|sel|unsel"` + `data-lavash-member-value`
  — array membership class toggling (the ChipSet pattern).
- `data-lavash-visible="field"` — show/hide via a `hidden` class.
- `data-lavash-enabled="field"` — enable/disable a button without a
  server roundtrip.

Hand-written `data-lavash-*` attributes still work for cases the
inference can't reach (non-bare expressions, `unless`, complex class
concatenation, async patterns).

### Overlays (modals, flyovers)

`animated:` state fields drive a phase machine
(`idle → entering → [loading] → visible → exiting → idle`). The optimistic
JS hook drives the transitions client-side. Modal and flyover DSLs are
built on top:

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

  template do
    ~H"""
    <div class="p-6">
      <.modal_close_button id={@__modal_id__} myself={@myself} />
      <!-- form content -->
    </div>
    """
  end
end
```

The overlay runs through phases (`idle → entering → [loading] → visible →
exiting → idle`); the optimistic JS hook drives the transitions
client-side.

---

## Cross-cutting concerns

### PubSub invalidation

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

### Using lavash without the DSL

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

## License

MIT
