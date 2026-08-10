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
    # client-side prediction — applied instantly
    map_by :items, :id, "fn item, _id -> %{item | quantity: item.quantity + 1} end"

    # durable write — pre-cascade, so the SAME event re-reads and the
    # diff the client receives already carries post-write truth
    pre_run fn socket ->
      item = Ash.get!(CartItem, socket.assigns.id)
      item |> Ash.Changeset.for_update(:update_quantity, %{quantity: item.quantity + 1}) |> Ash.update!()
      Lavash.PubSub.broadcast(CartItem)
      socket
    end
  end
end
```

The projected field is a **derive on the server** — always recomputed
from the read, never mutated by actions (`set` targeting it is a
compile error; `map_by` on it is client-only) — and **mutable
optimistic state on the client**. The reconciliation story:

1. Click → the transpiled `map_by` mutates the client copy instantly;
   calcs and subtree derives over it re-render.
2. The event reaches the server; `pre_run` writes the resource; the
   backing read is auto-marked dirty (because the action `map_by`s a
   projected field) and re-runs in the same cascade.
3. The reply's diff carries the post-write list — the client's
   SyncedVar sees a matching value and **confirms** the prediction
   (or corrects it, if the server disagreed).
4. `Lavash.PubSub.broadcast/1` invalidates the read in every other
   session on the same data; their SyncedVars have no pending
   prediction, so the fresh list is accepted directly.

Limitations: the backing read must be a query read (list result) with
`async false`; `fields` is an explicit allowlist (atoms for own
attributes, `assoc: [...]` for one level of loaded relationships);
values are wire-encoded (Decimal → string, atom → string, dates →
ISO 8601).

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
