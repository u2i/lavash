defmodule Lavash.ClientComponent do
  @moduledoc """
  A Spark-based component that renders on both server and client with optimistic updates.

  Uses Spark DSL for declarative definition of state, props, calculations,
  and optimistic actions.

  ## How It Works

  1. Server renders the full content via HEEx
  2. JS hook intercepts clicks and applies optimistic updates directly to DOM
  3. When server responds, hook compares versions:
     - If server is caught up: accept LiveView's DOM patch
     - If client is ahead: re-apply optimistic state after patch

  ## Usage

      defmodule MyApp.TagEditor do
        use Lavash.ClientComponent

        # State connects to parent state
        state :tags, {:array, :string}

        # Props from parent (read-only)
        prop :placeholder, :string, default: "Add tag..."
        prop :max_tags, :integer

        # Calculations run on both client and server
        calculate :can_add, @max_tags == nil or length(@tags) < @max_tags
        calculate :tag_count, length(@tags)

        # Optimistic actions - single definition for both client and server
        optimistic_action :add, :tags,
          run: fn tags, tag -> tags ++ [tag] end,
          validate: fn tags, tag -> tag not in tags end,
          max: :max_tags

        optimistic_action :remove, :tags,
          run: fn tags, tag -> Enum.reject(tags, &(&1 == tag)) end

        # Render function compiles to both HEEx and JS render function
        render fn assigns ->
          ~L\"\"\"
          <div class="flex flex-wrap gap-2 items-center">
            <span :for={tag <- @tags} class={@tag_class}>
              {tag}
              <button
                type="button"
                data-lavash-action="remove"
                data-lavash-state-field="tags"
                data-lavash-value={tag}
              >×</button>
            </span>
            <input
              :if={@can_add}
              type="text"
              placeholder={@placeholder}
              data-lavash-action="add"
              data-lavash-state-field="tags"
            />
          </div>
          \"\"\"
        end
      end

  ## Key Features

  - **Declarative actions**: Define the transformation once, get both client JS and server Elixir
  - **Type-safe bindings**: Connect to parent Lavash state with type declarations
  - **Isomorphic calculations**: Same calculation runs on both client and server
  - **Template transpilation**: HEEx template compiles to JS render function
  """

  use Spark.Dsl,
    default_extensions: [extensions: [Lavash.ClientComponent.Dsl]]

  @impl Spark.Dsl
  def handle_opts(_opts) do
    quote do
      use Phoenix.LiveComponent
      require Phoenix.LiveView.TagEngine
      require Phoenix.Component
      import Phoenix.Component
      import Lavash.Component.Conveniences, only: [toggle: 1, toggle: 2, multi_select: 2, multi_select: 3]
      import Lavash.Template.RenderMacro
      import Lavash.Sigil, only: [sigil_L: 2]

      # Mark module type for sigil context detection
      @__lavash_module_type__ :client_component

      Module.register_attribute(__MODULE__, :__lavash_calculations__, accumulate: true)
      Module.register_attribute(__MODULE__, :__lavash_optimistic_actions__, accumulate: true)
      Module.register_attribute(__MODULE__, :__lavash_toggle_states__, accumulate: true)
      Module.register_attribute(__MODULE__, :__lavash_multi_select_states__, accumulate: true)
      Module.register_attribute(__MODULE__, :__lavash_renders__, accumulate: true)

      @before_compile Lavash.ClientComponent.Compiler

      # Define humanize locally so it's available in templates
      defp humanize(value) when is_binary(value) do
        value
        |> String.replace("_", " ")
        |> String.replace("-", " ")
        |> String.capitalize()
      end

      defp humanize(value) when is_atom(value), do: humanize(Atom.to_string(value))
      defp humanize(value), do: to_string(value)
    end
  end

  @impl Spark.Dsl
  def handle_before_compile(_opts) do
    []
  end

  @doc """
  Converts a value to a human-readable string.
  """
  def humanize(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
    |> String.replace("-", " ")
    |> String.capitalize()
  end

  def humanize(value) when is_atom(value), do: humanize(Atom.to_string(value))
  def humanize(value), do: to_string(value)
end
