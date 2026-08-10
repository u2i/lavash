defmodule Lavash.Component do
  @moduledoc """
  Stateful Phoenix LiveComponents with the same DSL as `Lavash.LiveView`.

  Components can declare `prop`, `state`, `calculate`, `actions`, and render
  with a `template do ~H end` block. Inside a Lavash component,
  `phx-target={@myself}` is auto-injected on `phx-*` attrs and
  `__lavash_client_bindings__` propagates to nested `<.lavash_component>` calls.

  ## Example

      defmodule MyAppWeb.ProductCard do
        use Lavash.Component

        prop :product, :map, required: true

        state :expanded, :boolean, from: :socket, default: false, optimistic: true
        state :hovered, :boolean, default: false, optimistic: true

        calculate :show_actions, rx(@expanded or @hovered)

        actions do
          action :toggle_expand do
            set :expanded, rx(not @expanded)
          end
        end

        template do
          ~H\"\"\"
          <div phx-click="toggle_expand">
            <h3>{@product.name}</h3>
            <div :if={@show_actions}>...</div>
          </div>
          \"\"\"
        end
      end

  ## Extensions

  Add behavior plugins via the `extensions` option:

      use Lavash.Component, extensions: [Lavash.Overlay.Modal.Dsl]

  Available extensions:
  - `Lavash.Overlay.Modal.Dsl` — modal phase machine (entering/visible/exiting)
  - `Lavash.Overlay.Flyover.Dsl` — slide-in panel from screen edges

  ## State persistence modes

  Components use the same `from:` field as LiveViews. `from: :socket` is
  particularly useful for components — the per-component-id state map
  travels through the LiveView's assigns and survives reconnects.
  """

  use Spark.Dsl,
    default_extensions: [extensions: [Lavash.Component.Dsl]]

  # Spark's generated __using__ runs handle_opts through Code.eval_quoted,
  # which cannot install Phoenix.Component's @on_definition hook — so
  # attr/slot in user modules would fail (issue #20). Override the
  # (defoverridable) __using__ to splice the Phoenix.LiveComponent setup
  # into the caller's module body with real `use` semantics, then
  # delegate to Spark for everything else.
  defmacro __using__(opts) do
    [
      quote do
        # Replicate Phoenix.LiveComponent's __using__ but override sigil_H
        import Phoenix.LiveView
        @behaviour Phoenix.LiveComponent
        @before_compile Phoenix.LiveView.Renderer

        use Phoenix.Component,
            Keyword.merge([global_prefixes: []], Keyword.take(unquote(opts), [:global_prefixes]))

        @doc false
        def __live__, do: %{kind: :component, layout: false}
      end,
      super(opts)
    ]
  end

  @impl Spark.Dsl
  def handle_opts(_opts) do
    quote do
      # Mark module type for sigil context detection
      @__lavash_module_type__ :component

      # Register module attribute for render definitions
      Module.register_attribute(__MODULE__, :__lavash_renders__, accumulate: true)

      import Lavash.Template.RenderMacro
    end
  end

  @impl Spark.Dsl
  def handle_before_compile(opts) do
    extensions = Keyword.get(opts, :extensions, [])

    # Add extension DSLs to the list
    extension_list =
      Enum.flat_map(extensions, fn
        Lavash.Modal -> [Lavash.Modal.Dsl]
        other -> [other]
      end)

    if extension_list != [] do
      [single_extension_kinds: [:extensions], extensions: extension_list]
    else
      []
    end
  end
end
