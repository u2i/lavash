defmodule Lavash.LiveView.Base do
  @moduledoc """
  Layer-1+2+3 entry point: lavash without the optimistic UI layer.

  Use this in place of `Lavash.LiveView` when you want the Spark DSL
  surface (`state`, `calculate`, `read`, `form`, `actions`,
  `mount do`, `messages do`, etc.) but no client-side optimistic
  machinery — no SyncedVar, no merge walker, no JS rx transpilation,
  no `data-lavash-display` wrapping spans, no `LavashOptimistic`
  hook injection.

  ## Example

      defmodule MyAppWeb.AdminLive do
        use Lavash.LiveView.Base

        state :user, :map, from: :assigns, assigns_key: :current_user
        state :tab, :string, from: :url, default: "overview"

        actions do
          action :switch_tab, [:tab] do
            set :tab, &(&1.params.tab)
          end
        end

        template do
          ~H\"\"\"
          <div>
            <h1>{@user.name}</h1>
            <p>Active tab: {@tab}</p>
          </div>
          \"\"\"
        end
      end

  Every change is server-authoritative — clicks roundtrip to the
  server, the server recomputes, the diff comes back, the DOM
  updates. Same model as vanilla LiveView, with the Spark DSL on
  top for declarative state + URL sync + Ash reads + reactive
  calculations.

  ## What you give up

  - **`optimistic: true`** on state fields: a compile-time error.
    Server is the only writer; the client doesn't apply patches
    locally.
  - **`animated:`** on state fields: same.
  - **`optimistic: true`** on calculations: same.
  - **`data-lavash-display` auto-wrapping** of bare `{@field}`:
    not applied. Rendering goes straight through Phoenix's
    normal interpolation.
  - **JS bundle**: a layer-2 consumer of lavash only needs
    `state_sync.js` (the reconnect cache); the optimistic
    `lavash.js` and its concerns aren't loaded.

  ## What you keep

  - The full DSL surface: `state`, `calculate`, `read`, `form`,
    `actions`, `messages`, `async`, `mount`, `when_connected`,
    components, slots, `on_mount`, navigates, push_events,
    push_patches, redirects.
  - Compile-time validation: action/event references, `phx-value-*`
    matching action params, `@assign` references in HEEx.
  - URL sync via `from: :url` (server-side `push_patch` + client
    `history.replaceState`).
  - Socket sync via `from: :socket` (reconnect-survival cache).
  - Reactive calculations (`calculate :foo, rx(...)`) — recompute
    on dep change, server-side.
  - Async reads and calculations (`async: true`).

  ## Layering note

  This module exists per `docs/ARCHITECTURE.md` punchlist item #10.
  Layer 4 (optimism) is currently pay-for-what-you-use even with
  `use Lavash.LiveView` — if you don't mark any field
  `optimistic: true`, the optimistic transformers no-op. `Base` is
  the *explicit opt-out* form: it makes "no client-side optimism"
  a load-bearing contract that the schema enforces rather than a
  consequence of you not asking for it.
  """

  use Spark.Dsl,
    default_extensions: [extensions: [Lavash.Dsl, Lavash.Dsl.BaseStrict]]

  @impl Spark.Dsl
  def handle_opts(opts) do
    quote do
      use Phoenix.LiveView, unquote(opts)

      @__lavash_module_type__ :live_view
      @__lavash_layer__ :base

      # Register accumulators that the layer-1 compile pipeline still
      # reads via `@__lavash_*` (even if Base never appends to them).
      # Without these, the compiled module would emit warnings on
      # first read.
      Module.register_attribute(__MODULE__, :__lavash_optimistic_actions__, accumulate: true)
      Module.register_attribute(__MODULE__, :__lavash_renders__, accumulate: true)

      import Lavash.LiveView.Helpers
      import Lavash.Template.RenderMacro
    end
  end
end
