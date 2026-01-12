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
      # Uses AST post-processing to inject __lavash_client_bindings__ into component calls
      defmacro sigil_L({:<<>>, _meta, [template]} = sigil_ast, modifiers) when is_binary(template) do
        # Build the sigil_H call AST
        sigil_h_call = quote do: sigil_H(unquote(sigil_ast), unquote(modifiers))

        # Expand the sigil_H macro to get the compiled template AST
        expanded_ast = Macro.expand(sigil_h_call, __CALLER__)

        # Transform the expanded AST to inject client bindings
        Lavash.Template.ASTTransformer.inject_client_bindings(expanded_ast)
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
