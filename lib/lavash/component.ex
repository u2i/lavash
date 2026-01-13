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
      use Phoenix.LiveComponent, unquote(Keyword.drop(opts, [:extensions]))

      require Phoenix.Component
      import Phoenix.Component

      # Define ~L sigil for Lavash-enhanced HEEx templates
      # Uses Lavash.TagEngine with token transformer for unified processing
      defmacro sigil_L({:<<>>, _meta, [template]}, _modifiers) when is_binary(template) do
        caller = __CALLER__
        module = caller.module

        # Get metadata for token transformation (component context)
        metadata =
          try do
            case Lavash.Sigil.get_compile_time_metadata(module) do
              nil -> %{context: :component}
              m -> Map.put(m, :context, :component)
            end
          rescue
            _ -> %{context: :component}
          end

        # Compile with Lavash.TagEngine and token transformer
        opts = [
          engine: Lavash.TagEngine,
          file: caller.file,
          line: caller.line + 1,
          caller: caller,
          source: template,
          tag_handler: Phoenix.LiveView.HTMLEngine,
          token_transformer: Lavash.Template.TokenTransformer,
          lavash_metadata: metadata
        ]

        EEx.compile_string(template, opts)
      end

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
