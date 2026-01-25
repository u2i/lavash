defmodule Lavash.Component do
  @moduledoc """
  Provides Ash-like developer experience for Phoenix LiveComponents.

  ## Usage

      defmodule MyApp.ProductCard do
        use Lavash.Component

        props do
          prop :product, :map, required: true
          prop :on_select, :function
        end

        state do
          socket do
            field :expanded, :boolean, default: false
          end

          ephemeral do
            field :hovered, :boolean, default: false
          end
        end

        derived do
          field :show_actions, depends_on: [:expanded, :hovered],
            compute: fn %{expanded: e, hovered: h} -> e or h end
        end

        assigns do
          assign :product
          assign :expanded
          assign :hovered
          assign :show_actions
        end

        actions do
          action :toggle_expand do
            update :expanded, &(!&1)
          end
        end

        def render(assigns) do
          ~H\"\"\"
          <div phx-click="toggle_expand" phx-target={@myself}>
            <h3>{@product.name}</h3>
            <div :if={@show_actions}>...</div>
          </div>
          \"\"\"
        end
      end

  ## Extensions

  You can add behavior plugins via the `extensions` option:

      use Lavash.Component, extensions: [Lavash.Modal]

  Available extensions:
  - `Lavash.Modal` - Adds modal behavior (open/close state, escape handling, etc.)

  ## State Types

  - **props** - Passed from parent, read-only
  - **socket state** - Internal state that survives reconnects (synced to JS client)
  - **ephemeral state** - Internal state lost on reconnect
  - **derived state** - Computed from props + internal state
  """

  use Spark.Dsl,
    default_extensions: [extensions: [Lavash.Component.Dsl]]

  @impl Spark.Dsl
  def handle_opts(opts) do
    quote do
      # Replicate Phoenix.LiveComponent's __using__ but override sigil_H
      import Phoenix.LiveView
      @behaviour Phoenix.LiveComponent
      @before_compile Phoenix.LiveView.Renderer
      use Phoenix.Component, Keyword.merge([global_prefixes: []], Keyword.take(unquote(opts), [:global_prefixes]))

      @doc false
      def __live__, do: %{kind: :component, layout: false}

      # Import ~L sigil for Lavash component templates (context: :component)
      # This ensures proper binding injection for nested components
      # ~H still uses Phoenix.Component.sigil_H for standard HEEx
      import Lavash.Component.Sigil, only: [sigil_L: 2]

      @before_compile Lavash.Component.Compiler
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
