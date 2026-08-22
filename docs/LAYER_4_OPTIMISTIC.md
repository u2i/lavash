# Layer 4: Optimistic UI

Client-side instant feedback. `optimistic: true` on a state field or
calculation causes the rx transpiler to emit JS, the template
transformer to auto-inject `data-lavash-*` annotations, and the
`LavashOptimistic` JS hook to apply predictions client-side before the
server reply arrives. Under the hood: a per-hook SyncedVar store with
version tracking and a merge walker that reconciles server pushes
against in-flight optimistic state. The server is still the source of
truth — strip this layer out (`use Lavash.LiveView.Base`) and the app
still works, just with a round-trip-latency feel.

## Optimistic state

Add `optimistic: true` to make a field part of the client-side state map. The
lavash JS pipeline reads it from `data-lavash-state` and updates the DOM as
transpiled actions fire — before the server reply arrives.

```elixir
state :count, :integer, default: 0, optimistic: true
```

Without `optimistic: true`, the field still works server-side but every
update takes a full LiveView round-trip.

## Client-mapped resource lists (`client_state`)

A query read can project its record list onto the client as
optimistic state:

```elixir
read :cart_items, CartItem, :for_cart do
  argument :cart_id, prop(:cart_id)
  async false
  invalidate :pubsub

  client_state :items do
    key :id
    fields [:id, :quantity, :unit_price, product: [:id, :name]]
  end
end

calculate :subtotal, rx(Enum.reduce(@items || [], 0.0, ...))

actions do
  action :increment, [:id] do
    mutate :items, :update_quantity, rx(%{quantity: @item.quantity + 1})
  end

  action :decrement, [:id] do
    mutate :items, :update_quantity,
           rx(if @item.quantity <= 1, do: :remove, else: %{quantity: @item.quantity - 1})
  end

  action :remove, [:id] do
    remove :items
  end

  action :add, [:name] do
    append :items, :create, rx(%{cart_id: @cart_id, name: @name, quantity: 1})
  end

  action :add_by_key, [:product_id, :qty] do
    upsert :items,
      match: [:product_id],
      on_conflict: {:update_quantity, rx(%{quantity: @item.quantity + @qty})},
      on_insert: {:create, rx(%{cart_id: @cart_id, product_id: @product_id, quantity: @qty})}
  end
end
```

The projected field is a **derive on the server** — always recomputed
from the read, never mutated directly (`set` targeting it is a compile
error) — and **mutable optimistic state on the client**. Mutations go
through four ops, each a single declaration evaluated on both sides:

- `mutate :field, :ash_action, rx(...)` — the rx sees the matched row
  as `@item` and returns a params map or `:remove`. Client-side the
  result merges into the projected row (the instant prediction);
  server-side it drives the named Ash action on the authoritative
  record (`:remove` destroys it). The row is matched by the
  projection's `key`, taken from the action's same-named param.
- `remove :field` — keyed destroy (optional `action:` names the
  destroy action).
- `append :field, :create_action, rx(...)` — the rx returns the new
  row's attributes. The row's id is **client-generated**
  (`crypto.randomUUID()`, minted at click time and carried on the
  event), and the server creates the record under it — so the
  provisional row keeps its identity when the re-read lands, and
  follow-up mutations on a just-added row address the real record
  immediately. Server-side the attrs are filtered to the create
  action's accepted attributes and drive `Ash.create`.
- `upsert :field, match: [...], on_conflict: {action, rx}, on_insert:
  {action, rx}` — insert-or-update by a *semantic* identity (a cart
  keyed by product). A row whose `match` fields equal the action's
  params/state values is updated with the `on_conflict` params
  (`@item` bound, `:remove` drops it); otherwise the `on_insert` row
  is inserted, append-style under a client-generated id. Predicting
  the *merge* when the row exists is the point — an `append` +
  server-side dedup flashes a duplicate row that then collapses.
  Match fields must be projected own fields. The dedup rule lives in
  the lavash action, so back the semantic identity with an Ash
  `identity` when duplicates must be impossible.

Which op models which list is a question of **who can author the
row**: a self-contained fact the client fully knows (a todo) is
`append`; a row merged by a domain key against state that other
sessions race (a cart line) is `upsert`, whose branch decision and
server-derived fields (price snapshots) can be corrected by the
re-read; a row only the server can compute isn't predictable at all —
render a loading state, not a prediction.

The reconciliation story:

1. Click → the transpiled prediction mutates the client copy
   instantly; calcs and subtree derives over it re-render.
2. The event reaches the server; the op performs the Ash write, the
   resource is broadcast, and the backing read is auto-marked dirty —
   it re-runs in the same cascade.
3. The reply's diff carries the post-write list — the client's
   SyncedVar sees a matching value and **confirms** the prediction
   (or corrects it, if the server disagreed).
4. The broadcast invalidates the read in every other session on the
   same data; their SyncedVars have no pending prediction, so the
   fresh list is accepted directly.

### Cross-component predictions (`invoke`'s client half)

A page action can `invoke` a component's projection op, and the
prediction crosses the hook boundary: the transpiled page action runs
the target component's optimistic fn in the same tick as its own sets
(via a client-side hook registry), while the server half routes
through `send_update` as always:

```elixir
action :add_to_cart, [:product_id] do
  set :cart_open, true

  invoke "cart-flyover", :add_item,
    module: MyAppWeb.CartFlyover,
    params: [product_id: {:param, :product_id}, qty: 1]
end
```

The flyover's `:add_item` upsert then bumps its projected badge
instantly. If the target hook isn't mounted, the client half no-ops
and the server half still applies.

Limitations: the backing read must be a query read (list result) with
`async false`; `fields` is an explicit allowlist (atoms for own
attributes, `assoc: [...]` for one level of loaded relationships);
values are wire-encoded (Decimal → string, atom → string, dates →
ISO 8601). Keep `mutate` transforms to identity-encoded fields
(numbers, booleans, strings) — the client sees the projected row, the
server sees the raw record, and encoded fields differ between them.

## Strictness: broken optimistic promises fail the build

`optimistic: true` (the default for calcs) is a stated intent that the
code runs client-side. Code that can't fulfill it is a **compile
error**:

- an optimistic calc whose rx body isn't transpilable
- an optimistic calc depending on fields that never exist in client
  state (server-side reads, non-optimistic state) — it would throw on
  every client recompute
- an untranspilable rx `set` inside an optimistic action (the
  server-only function form `set :f, fn ctx -> ... end` remains the
  sanctioned escape hatch)
- an untranspilable `mutate`/`append`/`upsert` transform (these have
  no `optimistic: false` escape — the prediction *is* the op's client
  half)

Each error message prescribes its fix. Opportunistically-extracted
attr derives stay warnings — `class={...}` never declared optimism, so
a server-rendered fallback is legitimate.

Transitional escape hatch (restores warn-and-demote):

```elixir
config :lavash, :untranspilable_optimistic, :warn
```

## DOM annotations

The layer-4 reach into HEEx is the family of `data-lavash-*`
attributes the JS hook reads to update the DOM without a round-trip.
Most are **auto-injected** by the template transformer when an
idiomatic expression resolves against an optimistic field; a small
set are **hand-written escape hatches** for what inference can't
reach. The annotation is the contract either way — the hook doesn't
care who wrote it.

### Auto-injected

You don't write these by hand:

- `data-lavash-display="field"` — bare `{@field}` interpolations are
  wrapped in a span the hook re-texts directly.
- `data-lavash-bind="field"` — inputs with `value={@field}`, selects
  whose `<option selected={@field == …}>` expressions agree on one
  field, and textareas with a bare `{@field}` body.
- `data-lavash-attr-<name>="__attr_N_<name>"` — **the general
  mechanism for reactive attributes.** Any `class=`/`disabled=`/
  `hidden=` expression referencing optimistic fields is transpiled
  into a derive the client re-evaluates, then re-applies to the
  attribute (class values get Phoenix class-list semantics: flatten,
  drop `nil`/`false`, space-join). Conditional classes of any shape —
  `if`/`unless`, list form, string concatenation, comparisons — ride
  this. Untranspilable expressions demote loudly to server-rendered.
- `data-lavash-enabled="field"` — from `disabled={not @field}`.
- `data-lavash-member="field|sel|unsel"` + `data-lavash-member-value`
  — from `class={if val in @list, …}` (the ChipSet pattern). Kept as
  its own directive because chip rows live inside `:for` loops,
  where attribute derives can't go (loop variables don't exist in
  derive scope) — the per-row value rides `phx-value-val`.
- Form-field wiring (`bind`/`form`/`field`/`valid`) — from
  `field={@form[:name]}` or `name={@form[:name].name}` shorthands.
  Note: a hand-written `data-lavash-bind` on such an element
  *suppresses* the rest of this injection — prefer the shorthand.

Injection fires on **HTML tags only**. Attributes on component calls
(`<.form>`, `<.button>`) are invisible to the pipeline even when the
component passes them through — annotate those by hand (below).

Note on `:if={@field}`: those blocks ride **subtree derives** — the
block re-renders client-side in both directions — so no annotation
is injected for them at all.

### Hand-written escape hatches

These are supported public API — each exists because no idiomatic
expression can carry the information:

- `data-lavash-visible="field"` — show/hide via a `hidden` class in
  **non-lavash templates** (inside lavash templates, `:if` subtree
  derives and hidden-class attribute derives cover both shapes).

- `data-lavash-display="field"` — around an expression the pipeline
  won't manage itself, which in practice means **async render
  blocks** (a `case` over an AsyncResult) and non-lavash templates:
  tells the hook which field's changes should re-text this element
  with the raw client value. (For *sync* optimistic fields there is
  no gap to escape: transpilable non-bare expressions become subtree
  derives automatically, and untranspilable ones are compile errors
  under optimistic strictness — move those into a `calculate`.)
- `data-lavash-toggle="field|on|off"` — class switching in places
  the pipeline can't reach: component calls and non-lavash (`~H`)
  templates. Inside lavash templates, write the conditional in
  `class={…}` and let the attribute derive handle it.
- `data-lavash-action="name"` — an input that commits an action on
  Enter (the todos add box). Mints client row ids for `append`
  predictions the same way `phx-click` handlers do.
- `data-lavash-id={row.id}` — row identity for list children: opts
  the row into provisional marking (`data-lavash-provisional` until
  the server confirms) and lets predictions target the right node.
- `data-lavash-valid="custom_calc"` — overrides the generated
  `<form>_<field>_valid` with your own calculation (pairs with
  `extend_errors`; the `valid_field` attr on `<.input>` does this
  for you).
- `data-lavash-manual` — opt-out: suppresses all auto-injection on
  the element.

## Overlays (modals, flyovers)

`animated:` state fields drive a phase machine
(`idle → entering → [loading] → visible → exiting → idle`). The optimistic
JS hook drives the transitions client-side. Modal and flyover DSLs are
built on top:

```elixir
defmodule MyAppWeb.ProductModal do
  use Lavash.Component, extensions: [Lavash.Overlay.Modal.Dsl]
  import Lavash.Overlay.Modal.Helpers

  modal do
    open_field :product_id  # nil = closed, any non-nil value = open
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

### Triggers (`template_trigger`)

An overlay component can own its trigger — rendered **outside** the
panel chrome, in normal page flow, wrapped in a button that opens the
overlay optimistically and carries the dialog ARIA contract
(`aria-haspopup="dialog"`, `aria-expanded` kept current client-side,
`aria-controls`):

```elixir
template_trigger do
  ~H"""
  <span class="btn btn-ghost">Cart ({@item_count})</span>
  """
end
```

Trigger content goes through the same template pipeline as everything
else (optimistic display spans, toggles), so a badge computed from a
`client_state` projection updates instantly. Keep the content
non-interactive (spans/icons — the wrapper is the button), and note
the generated open sets the open field to `true`; overlays whose open
field carries a value (an id) still open via actions. With a trigger,
parents place the component where the trigger belongs and pass data —
no icon markup, open action, or count plumbing of their own.

> #### Closed means `nil`, not `false` {: .warning}
>
> The overlay convention on both sides of the wire is: `nil` = closed,
> **any** non-nil value = open — including `false`. A close action
> written as `set :open, false` compiles and runs but never closes the
> overlay. Either rely on the plugin-injected `:close` action (which
> sets the open field to `nil`), or set `nil` explicitly.
