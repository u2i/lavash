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

> #### Closed means `nil`, not `false` {: .warning}
>
> The overlay convention on both sides of the wire is: `nil` = closed,
> **any** non-nil value = open — including `false`. A close action
> written as `set :open, false` compiles and runs but never closes the
> overlay. Either rely on the plugin-injected `:close` action (which
> sets the open field to `nil`), or set `nil` explicitly.
