defmodule Lavash.Component.Compiler do
  @moduledoc """
  Compiles the Lavash Component DSL into LiveComponent callbacks.
  """

  defmacro __before_compile__(env) do
    # Check if an overlay registered a render generator
    render_generator = Spark.Dsl.Extension.get_persisted(env.module, :lavash_overlay_render_generator)

    # Get optimistic colocated data if available (persisted by ColocatedTransformer)
    # Escape immediately to avoid "tried to unquote invalid AST" errors during incremental compilation
    optimistic_colocated_data =
      case Spark.Dsl.Extension.get_persisted(env.module, :lavash_optimistic_colocated_data) do
        nil -> nil
        data -> Macro.escape(data)
      end

    # Check for render definitions from the new macro-based approach
    lavash_renders = Module.get_attribute(env.module, :__lavash_renders__) || []

    # Determine render source - priority: overlay generator > macro renders > user-defined
    render_function =
      cond do
        render_generator ->
          # Overlay's render generator takes precedence
          render_generator.generate(env.module)

        lavash_renders != [] ->
          # Generate from macro-based renders
          generate_render_from_macros(lavash_renders, env)

        true ->
          # Fall back to user-defined render/1
          quote do
          end
      end

    # Track the helpers path for recompilation if a generator is present
    external_resource =
      if render_generator do
        helpers_path = render_generator.helpers_path()

        quote do
          @external_resource unquote(helpers_path)
        end
      else
        quote do
        end
      end

    quote do
      unquote(external_resource)

      @impl Phoenix.LiveComponent
      def update(assigns, socket) do
        Lavash.Component.Runtime.update(__MODULE__, assigns, socket)
      end

      @impl Phoenix.LiveComponent
      def handle_event(event, params, socket) do
        Lavash.Component.Runtime.handle_event(__MODULE__, event, params, socket)
      end

      unquote(render_function)

      # Introspection functions - entities from top_level? sections
      def __lavash__(:props) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:props])
      end

      def __lavash__(:states) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:states])
      end

      def __lavash__(:reads) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:reads])
      end

      def __lavash__(:forms) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:forms])
      end

      def __lavash__(:derived_fields) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:derives])
        |> Enum.map(&Lavash.LiveView.Compiler.normalize_derived/1)
      end

      def __lavash__(:calculations) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:calculations])
      end

      # Expose calculations for Graph module
      # Returns 7-tuples: {name, source, ast, deps, optimistic, async, reads}
      def __lavash_calculations__ do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:calculations])
        |> Enum.map(fn calc ->
          {calc.name, calc.rx.source, calc.rx.ast, calc.rx.deps,
           Map.get(calc, :optimistic, true),
           Map.get(calc, :async, false),
           Map.get(calc, :reads, [])}
        end)
      end

      def __lavash__(:actions) do
        declared_actions = Spark.Dsl.Extension.get_entities(__MODULE__, [:actions])
        setter_actions = Lavash.LiveView.Compiler.generate_setter_actions(__MODULE__)
        declared_actions ++ setter_actions
      end

      # Convenience accessors by storage type
      def __lavash__(:socket_fields) do
        __lavash__(:states) |> Enum.filter(&(&1.from == :socket))
      end

      def __lavash__(:ephemeral_fields) do
        __lavash__(:states) |> Enum.filter(&(&1.from == :ephemeral))
      end

      def __lavash__(:optimistic_fields) do
        __lavash__(:states) |> Enum.filter(&(&1.optimistic == true))
      end

      # Components don't have URL fields
      def __lavash__(:url_fields), do: []

      # Phoenix colocated JS integration for optimistic functions
      if unquote(not is_nil(optimistic_colocated_data)) do
        # optimistic_colocated_data is already escaped, so just unquote it directly
        @__lavash_optimistic_colocated_data__ unquote(optimistic_colocated_data)
        def __phoenix_macro_components__ do
          %{
            Phoenix.LiveView.ColocatedJS => [@__lavash_optimistic_colocated_data__]
          }
        end
      end
    end
  end

  @doc """
  Generate render/1 function from macro-based render definitions.

  Syntax: `render fn assigns -> ~L\"\"\"...\"\"\" end`
  """
  def generate_render_from_macros(renders, _env) do
    renders_map = Map.new(renders)

    # Check for function-based render
    case Map.get(renders_map, :__render_fn__) do
      nil ->
        # No render defined via macro
        quote do end

      escaped_fn ->
        # Function-based render - function AST is escaped
        generate_render_from_fn(escaped_fn)
    end
  end

  # Generate render from function syntax: render fn assigns -> ~L"..." end
  defp generate_render_from_fn(escaped_fn) do
    quote do
      @impl Phoenix.LiveComponent
      def render(var!(assigns)) do
        render_fn = unquote(escaped_fn)
        render_fn.(var!(assigns))
      end
    end
  end

end
