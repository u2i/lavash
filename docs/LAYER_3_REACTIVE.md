# Layer 3: Reactive expressions

The server-side reactive graph engine. `calculate :foo, rx(...)` and
`rx(...)` inside action bodies (e.g. `set :count, rx(@count + 1)`) are
the two surface forms. The compiler builds a topologically ordered
dependency graph and recomputes only affected derives on every state
change.

## Reactive expressions: `rx`

`rx(...)` captures an expression at compile time. References to `@field` are
tracked as dependencies. The same expression compiles to both Elixir (for
server-side evaluation) and JavaScript (for the optimistic hook — layer 4).

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

### Forms vs. `data-lavash-bind` on submit

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

## Cookbook: a full form-submission recipe

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
