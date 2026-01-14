# Lavash Component Model

Lavash is a declarative state management framework for Phoenix LiveView built on Spark DSL and Ash resources. It provides:

- **Reactive state graph** - Automatic dependency tracking and topological recomputation
- **Isomorphic updates** - Server-side and client-side computation from the same declarations
- **Optimistic UI** - Instant client feedback with server reconciliation
- **Nested component binding** - Parent-child state propagation with automatic resolution

## Component Types

Lavash provides three component types for different use cases:

| Type | Purpose | State Ownership | Rendering |
|------|---------|-----------------|-----------|
| `Lavash.LiveView` | Pages with URL sync, PubSub | Owns all state | Server |
| `Lavash.Component` | Reusable UI with internal state | Owns internal state, receives props | Server |
| `Lavash.ClientComponent` | Optimistic UI components | Binds to parent state | Server + Client |

## LiveView

LiveViews are stateful pages that own their state and can sync with URL parameters.

```elixir
defmodule MyApp.ProductsLive do
  use Lavash.LiveView

  # State from URL (survives page refresh, enables deep linking)
  state :search, :string, from: :url, default: ""
  state :page, :integer, from: :url, default: 1

  # State persisted to client (survives reconnects)
  state :view_mode, :string, from: :socket, default: "grid"

  # Ephemeral state (lost on reconnect)
  state :expanded_id, :string, from: :ephemeral

  # Load data from Ash resources
  read :products, Product, :list do
    argument :search, state(:search)
    argument :page, state(:page)
  end

  # Reactive calculations (auto-transpiled to JavaScript)
  calculate :has_results, rx(length(@products) > 0)
  calculate :showing, rx("Page #{@page} of #{@total_pages}")

  # Actions respond to events
  actions do
    action :search, [:query] do
      set :search, &(&1.params.query)
      set :page, 1
    end

    action :next_page do
      update :page, &(&1 + 1)
    end
  end

  template """
  <div>
    <input phx-change="search" phx-value-query={@search} />
    <div :for={product <- @products}>{product.name}</div>
    <button phx-click="next_page" :if={@has_results}>Next</button>
  </div>
  """
end
```

### State Storage Types

| Storage | Behavior | Use Case |
|---------|----------|----------|
| `:url` | Syncs to URL query params | Search, filters, pagination |
| `:socket` | Persisted to client, survives reconnect | View preferences |
| `:ephemeral` | Socket-only, lost on reconnect | UI state like expanded items |

### URL State Options

```elixir
# Custom encoding for complex types
state :selected_ids, {:array, :integer}, from: :url,
  encode: fn ids -> Enum.join(ids, ",") end,
  decode: fn str -> String.split(str, ",") |> Enum.map(&String.to_integer/1) end

# Default values
state :sort, :string, from: :url, default: "name"
```

## Component

Components are reusable LiveComponents with their own internal state. They receive props from parents and can notify parents of events.

```elixir
defmodule MyApp.ProductCard do
  use Lavash.Component

  # Props from parent (read-only)
  prop :product, :map, required: true
  prop :on_select, :string

  # Internal state
  state :expanded, :boolean, from: :ephemeral, default: false

  # Calculations depend on props and state
  calculate :show_details, rx(@expanded and @product.has_details)

  actions do
    action :toggle do
      update :expanded, &(not &1)
    end

    action :select do
      notify_parent :on_select  # Sends event to parent
    end
  end

  def render(assigns) do
    ~H"""
    <div phx-click="toggle" phx-target={@myself}>
      <h3>{@product.name}</h3>
      <div :if={@show_details}>{@product.description}</div>
      <button phx-click="select" phx-target={@myself}>Select</button>
    </div>
    """
  end
end
```

### Props vs State

- **Props**: Passed from parent, read-only, trigger recomputation when changed
- **State**: Owned by component, mutable via actions

### Notify Parent

Components communicate upward via `notify_parent`:

```elixir
# In component
prop :on_saved, :string, required: true

actions do
  action :save do
    submit :form, on_success: :handle_success
  end

  action :handle_success do
    notify_parent :on_saved  # Uses prop value as event name
  end
end

# In parent template
<.live_component module={MyApp.ProductCard} id="card" on_saved="product_saved" />

# Parent receives: handle_event("product_saved", ...)
```

## ClientComponent

ClientComponents provide optimistic UI updates. State changes are applied immediately on the client, then reconciled with the server.

```elixir
defmodule MyApp.TagEditor do
  use Lavash.ClientComponent

  # State binds to parent field
  state :tags, {:array, :string}

  # Props (client: false excludes from JS state)
  prop :max_tags, :integer, client: false

  # Calculations transpiled to JavaScript
  calculate :can_add, rx(@max_tags == nil or length(@tags) < @max_tags)
  calculate :tag_count, rx(length(@tags))

  # Optimistic actions run on both client and server
  optimistic_action :add, :tags,
    run: fn tags, tag -> tags ++ [tag] end,
    validate: fn tags, tag -> tag not in tags end,
    max: :max_tags

  optimistic_action :remove, :tags,
    run: fn tags, tag -> Enum.reject(tags, &(&1 == tag)) end

  template """
  <div>
    <span :for={tag <- @tags}>
      {tag}
      <button data-lavash-action="remove" data-lavash-value={tag}>x</button>
    </span>
    <input data-lavash-action="add" :if={@can_add} />
  </div>
  """
end
```

### Optimistic Action Options

```elixir
optimistic_action :update_qty, :items,
  key: :id,                    # For array of objects, match by this field
  run: fn item, delta ->       # Transform function (server)
    %{item | qty: item.qty + delta}
  end,
  validate: fn item, delta ->  # Validation (optional)
    item.qty + delta >= 0
  end,
  max: :max_qty                # Max constraint from prop
```

### Binding to Parent

ClientComponents bind their state to parent fields:

```elixir
# Parent LiveView
state :product_tags, {:array, :string}, from: :ephemeral, default: []

# In template
<.live_component
  module={MyApp.TagEditor}
  id="tag-editor"
  bind={[tags: :product_tags]}  # Child :tags binds to parent :product_tags
  tags={@product_tags}
/>
```

When the child updates `:tags`, the change propagates to parent's `:product_tags`.

## Reactive Expressions

The `rx()` macro captures Elixir expressions and makes them reactive:

```elixir
# Simple calculations
calculate :doubled, rx(@count * 2)
calculate :full_name, rx("#{@first_name} #{@last_name}")

# Conditionals
calculate :status, rx(if @count > 0, do: "active", else: "empty")

# List operations
calculate :total, rx(Enum.sum(Enum.map(@items, & &1.price)))
calculate :filtered, rx(Enum.filter(@items, & &1.active))

# Boolean logic
calculate :can_submit, rx(@form_valid and not @submitting)
```

### Supported Operations

| Category | Examples |
|----------|----------|
| Arithmetic | `+`, `-`, `*`, `/`, `rem` |
| Comparison | `==`, `!=`, `>`, `<`, `>=`, `<=` |
| Boolean | `and`, `or`, `not` |
| Conditionals | `if/else`, `case` (simple) |
| String | `<>`, interpolation |
| List | `length`, `++`, `Enum.map`, `Enum.filter`, `Enum.sum` |
| Access | `@field`, `@map.key`, `@map["key"]` |

### Reusable Functions with defrx

```elixir
# Define reusable reactive functions
defrx valid_email?(email) do
  String.length(email || "") > 0 and String.contains?(email, "@")
end

defrx format_price(cents) do
  "$#{div(cents, 100)}.#{rem(cents, 100) |> Integer.to_string() |> String.pad_leading(2, "0")}"
end

# Use in calculations
calculate :email_valid, rx(valid_email?(@email))
calculate :display_price, rx(format_price(@price_cents))

# Import from other modules
import_rx MyApp.Validators, only: [valid_email?: 1]
```

## Derived Fields

For complex computations that can't be expressed with `rx()`, use `derive`:

```elixir
derive :summary do
  async false  # Run synchronously (default)
  optimistic true  # Include in client state

  argument :items, state(:items)
  argument :tax_rate, prop(:tax_rate)

  run fn %{items: items, tax_rate: rate}, _context ->
    subtotal = Enum.sum(Enum.map(items, & &1.price * &1.qty))
    tax = Decimal.mult(subtotal, rate)
    %{subtotal: subtotal, tax: tax, total: Decimal.add(subtotal, tax)}
  end
end
```

### Async Derives

```elixir
derive :external_data do
  async true  # Runs in Task, result wrapped in AsyncResult

  argument :id, state(:product_id)

  run fn %{id: id}, _context ->
    ExternalAPI.fetch_product_data(id)
  end
end

# In template
<%= case @external_data do %>
  <% %AsyncResult{loading: true} -> %>
    <span>Loading...</span>
  <% %AsyncResult{ok?: true, result: data} -> %>
    <span>{data.value}</span>
  <% %AsyncResult{failed: error} -> %>
    <span>Error: {inspect(error)}</span>
<% end %>
```

## Reading Ash Resources

The `read` DSL loads data from Ash resources with automatic dependency tracking:

```elixir
# Simple read by ID
read :product, Product do
  id state(:product_id)
end

# Read with action and arguments
read :products, Product, :list do
  argument :category_id, state(:category_id)
  argument :search, state(:search)
  async false  # Synchronous (default true for lists)
end

# Transform to options for select
read :categories, Category, :list do
  as_options label: :name, value: :id
end
# Result: [{label: "Electronics", value: "uuid-123"}, ...]

# PubSub invalidation
read :products, Product, :list do
  argument :category_id, state(:category_id)
  invalidate_on [:category_id, :in_stock]  # Refresh when these change on any record
end
```

## Forms

Forms integrate with AshPhoenix for validation and submission:

```elixir
# Auto-detects create vs update based on data
form :form, Product do
  data result(:product)  # nil = create, loaded = update
end

# Form params are auto-created as ephemeral state
# @form_params, @form_errors, @form_valid are auto-generated

# Validation
extend_errors :email_errors do
  error rx(not String.contains?(@email || "", "@")), "Must contain @"
  error rx(String.length(@email || "") < 5), "Too short"
end

# Actions with form submission
actions do
  action :save do
    submit :form, on_success: :saved, on_error: :failed
  end

  action :saved do
    flash :info, "Product saved!"
    navigate "/products"
  end

  action :failed do
    flash :error, "Please fix errors"
  end
end
```

### Form in Template

```elixir
template """
<.form for={@form} phx-submit="save" phx-change="validate_form">
  <input field={@form[:name]} />
  <.field_errors field={:name} errors={@form_errors} />

  <input field={@form[:email]} />
  <.field_errors field={:email} errors={@email_errors} />

  <button type="submit" disabled={not @form_valid}>Save</button>
</.form>
"""
```

## Actions

Actions are declarative state transformers:

```elixir
actions do
  # Simple action
  action :increment do
    update :count, &(&1 + 1)
  end

  # Action with parameters
  action :set_count, [:value] do
    set :count, &String.to_integer(&1.params.value)
  end

  # Conditional action
  action :submit, when: :can_submit do
    set :submitting, true
    submit :form, on_success: :success, on_error: :error
  end

  # Action with effects
  action :log_view do
    effect fn state, _params, socket ->
      Analytics.track("view", %{id: state.product_id})
      socket
    end
  end

  # Multiple operations
  action :reset do
    set :search, ""
    set :page, 1
    set :filters, %{}
    flash :info, "Filters cleared"
  end
end
```

### Action Operations

| Operation | Description |
|-----------|-------------|
| `set :field, value_fn` | Set field to computed value |
| `update :field, transform_fn` | Transform current value |
| `effect fn state, params, socket -> socket end` | Side effects |
| `submit :form, on_success: :action, on_error: :action` | Submit form |
| `navigate "/path"` | Push navigate |
| `flash :level, "message"` | Flash message |
| `notify_parent :prop_name` | Send event to parent (Component only) |
| `invoke :action, :component_id, params` | Call action on child component |

## Nested Component Bindings

Lavash handles deep component nesting with automatic binding resolution:

```elixir
# LiveView owns the state
defmodule MyApp.PageLive do
  use Lavash.LiveView
  state :count, :integer, from: :ephemeral, default: 0

  template """
  <.live_component
    module={MyApp.Wrapper}
    id="wrapper"
    bind={[count: :count]}
    count={@count}
  />
  """
end

# Intermediate component passes binding through
defmodule MyApp.Wrapper do
  use Lavash.Component
  state :count, :integer, from: :ephemeral, default: 0

  def render(assigns) do
    ~L"""
    <.child_component
      module={MyApp.Counter}
      id="counter"
      bind={[count: :count]}
      count={@count}
      myself={@myself}
    />
    """
  end
end

# ClientComponent at the leaf
defmodule MyApp.Counter do
  use Lavash.ClientComponent
  state :count, :integer

  optimistic_action :increment, :count,
    run: fn count, _ -> count + 1 end
end
```

The binding chain `count -> count -> count` is automatically resolved. When Counter increments, the change propagates up through Wrapper to PageLive.

### The ~L Sigil

Use `~L` instead of `~H` in Lavash components to enable automatic binding propagation:

```elixir
def render(assigns) do
  ~L"""
  <.child_component module={...} />
  """
end
```

The `~L` sigil automatically injects `__lavash_client_bindings__` on component calls, enabling the binding resolution chain.

## Extensions

### Modal

```elixir
defmodule MyApp.ProductModal do
  use Lavash.Component, extensions: [Lavash.Overlay.Modal.Dsl]

  modal do
    open_field :product_id    # nil = closed, truthy = open
    close_on_escape true
    close_on_backdrop true
    max_width :lg             # :sm, :md, :lg, :xl, :2xl, :full
    async_assign :product     # Wrap with AsyncResult handling
  end

  prop :product_id, :string

  read :product, Product do
    id prop(:product_id)
  end

  renders do
    render fn assigns ->
      ~H"""
      <h2>{@product.name}</h2>
      <p>{@product.description}</p>
      """
    end

    render_loading fn assigns ->
      ~H"<div>Loading...</div>"
    end
  end
end

# Usage
<.live_component module={MyApp.ProductModal} id="modal" product_id={@selected_id} />
```

### Flyover

```elixir
defmodule MyApp.CartFlyover do
  use Lavash.Component, extensions: [Lavash.Overlay.Flyover.Dsl]

  flyover do
    open_field :open
    slide_from :right        # :left, :right, :top, :bottom
    width :md                # For left/right
    close_on_escape true
    close_on_backdrop true
  end

  # ... state, reads, actions, renders
end
```

## Template DSL

LiveViews can use the `template` macro instead of defining `render/1`:

```elixir
defmodule MyApp.CounterLive do
  use Lavash.LiveView

  state :count, :integer, from: :url, default: 0
  calculate :doubled, rx(@count * 2)

  actions do
    action :increment do
      update :count, &(&1 + 1)
    end
  end

  template """
  <div>
    <span data-lavash-display="count">{@count}</span>
    <span data-lavash-display="doubled">{@doubled}</span>
    <button phx-click="increment">+</button>
  </div>
  """
end
```

The `template` macro:
1. Compiles HEEx at build time
2. Auto-injects `data-lavash-*` attributes for optimistic updates
3. Wraps with optimistic state handling

## Data Attributes

Lavash uses data attributes for client-side integration:

| Attribute | Purpose |
|-----------|---------|
| `data-lavash-display="field"` | Element displays this field's value |
| `data-lavash-bind="field"` | Input binds to this field |
| `data-lavash-action="name"` | Button triggers this action |
| `data-lavash-value="value"` | Value passed to action |
| `data-lavash-visible="field"` | Show/hide based on boolean field |
| `data-lavash-enabled="field"` | Enable/disable based on boolean field |
| `data-lavash-manual` | Opt out of automatic attribute injection |

## Lifecycle

### LiveView

```
mount/3
  ├── Subscribe to PubSub
  ├── Hydrate state (URL → socket → ephemeral)
  ├── Initialize forms
  ├── Compute dependency graph
  └── Project assigns

handle_params/3
  ├── Update URL state
  ├── Recompute affected fields
  └── Update PubSub subscriptions

handle_event/3
  ├── Apply form bindings (if validate event)
  ├── Find matching action
  ├── Execute action steps
  ├── Recompute dirty fields
  └── Sync URL/socket state

handle_info/2
  ├── :lavash_async → Deliver async results
  ├── :lavash_invalidate → Recompute from PubSub
  └── :lavash_component_* → Handle child events
```

### Component

```
update/2 (mount)
  ├── Initialize internal state
  ├── Store binding map
  ├── Compute dependency graph
  └── Project assigns

update/2 (subsequent)
  ├── Check for prop changes
  ├── Mark changed props as dirty
  ├── Recompute affected fields
  └── Project assigns

handle_event/3
  └── Same as LiveView (minus navigation)
```

## Best Practices

### State Design

1. **Prefer URL state** for anything shareable (search, filters, pagination)
2. **Use socket state** for user preferences that should survive reconnects
3. **Use ephemeral state** for transient UI state (expanded items, hover states)
4. **Use ClientComponent bindings** for real-time, optimistic UI

### Performance

1. **Minimize dependencies** in calculations to reduce recomputation
2. **Use async derives** for expensive computations
3. **Use read invalidation** instead of polling
4. **Prefer `calculate`** over `derive` when possible (simpler dependency tracking)

### Component Composition

1. **LiveView**: Page-level, owns all persistent state
2. **Component**: Reusable UI with internal state, communicates via props/notify_parent
3. **ClientComponent**: Optimistic UI, binds to parent state, updates propagate automatically

### Form Handling

1. Let Lavash auto-detect create vs update from `data` result
2. Use `extend_errors` for custom validation beyond Ash constraints
3. Use `skip_constraints` to disable Ash validation for specific fields
4. Submit via actions for clear success/error handling
