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
end
```

The projected field is a **derive on the server** — always recomputed
from the read, never mutated directly (`set` targeting it is a compile
error) — and **mutable optimistic state on the client**. Mutations go
through three ops, each a single declaration evaluated on both sides:

- `mutate :field, :ash_action, rx(...)` — the rx sees the matched row
  as `@item` and returns a params map or `:remove`. Client-side the
  result merges into the projected row (the instant prediction);
  server-side it drives the named Ash action on the authoritative
  record (`:remove` destroys it). The row is matched by the
  projection's `key`, taken from the action's same-named param.
- `remove :field` — keyed destroy (optional `action:` names the
  destroy action).
- `append :field, :create_action, rx(...)` — the rx returns the new
  row's attributes. Client-side it becomes a *provisional* row with a
  temp key (applied non-pending, so the re-read's real record replaces
  it); server-side it drives `Ash.create`, filtered to the action's
  accepted attributes.

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

Limitations: the backing read must be a query read (list result) with
`async false`; `fields` is an explicit allowlist (atoms for own
attributes, `assoc: [...]` for one level of loaded relationships);
values are wire-encoded (Decimal → string, atom → string, dates →
ISO 8601). Keep `mutate` transforms to identity-encoded fields
(numbers, booleans, strings) — the client sees the projected row, the
server sees the raw record, and encoded fields differ between them.

## Auto-injected DOM annotations

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

> #### Closed means `nil`, not `false` {: .warning}
>
> The overlay convention on both sides of the wire is: `nil` = closed,
> **any** non-nil value = open — including `false`. A close action
> written as `set :open, false` compiles and runs but never closes the
> overlay. Either rely on the plugin-injected `:close` action (which
> sets the open field to `nil`), or set `nil` explicitly.
