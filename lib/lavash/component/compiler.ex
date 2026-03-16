defmodule Lavash.Component.Compiler do
  @moduledoc """
  Compiles the Lavash Component DSL into LiveComponent callbacks.
  """

  defmacro __before_compile__(env) do
    # Check if an overlay registered a render generator
    render_generator = Spark.Dsl.Extension.get_persisted(env.module, :lavash_overlay_render_generator)

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
        states = __lavash__(:states)
        explicitly_optimistic = Enum.filter(states, &Lavash.State.Field.optimistic?/1)

        # Auto-detect: fields touched by transpilable actions
        actions = Spark.Dsl.Extension.get_entities(__MODULE__, [:actions]) || []
        action_touched_fields =
          actions
          |> Enum.filter(&Lavash.Optimistic.ActionJs.action_is_optimistic?/1)
          |> Enum.flat_map(fn action ->
            sets = action.sets || []
            map_bys = action.map_bys || []
            Enum.map(sets, & &1.field) ++ Enum.map(map_bys, & &1.field)
          end)
          |> MapSet.new()

        explicit_names = MapSet.new(explicitly_optimistic, & &1.name)
        auto_optimistic =
          states
          |> Enum.filter(fn f -> f.name in action_touched_fields and f.name not in explicit_names end)

        explicitly_optimistic ++ auto_optimistic
      end

      # Components don't have URL fields
      def __lavash__(:url_fields), do: []

      # Phoenix colocated integration for optimistic functions and client hooks
      unquote(generate_phoenix_macro_components(env))
    end
  end

  defp generate_phoenix_macro_components(env) do
    optimistic_colocated_data =
      case Spark.Dsl.Extension.get_persisted(env.module, :lavash_optimistic_colocated_data) do
        nil -> nil
        data -> Macro.escape(data)
      end

    client_hook_data =
      case Spark.Dsl.Extension.get_persisted(env.module, :lavash_client_hook_data) do
        nil -> nil
        data -> Macro.escape(data)
      end

    client_hook_name =
      Spark.Dsl.Extension.get_persisted(env.module, :lavash_client_hook_name)

    cond do
      optimistic_colocated_data && client_hook_data ->
        quote do
          @__lavash_optimistic_colocated_data__ unquote(optimistic_colocated_data)
          @__lavash_client_hook_data__ unquote(client_hook_data)
          def __full_hook_name__, do: unquote(client_hook_name)
          def __phoenix_macro_components__ do
            %{
              Phoenix.LiveView.ColocatedJS => [@__lavash_optimistic_colocated_data__],
              Phoenix.LiveView.ColocatedHook => [@__lavash_client_hook_data__]
            }
          end
        end

      client_hook_data ->
        quote do
          @__lavash_client_hook_data__ unquote(client_hook_data)
          def __full_hook_name__, do: unquote(client_hook_name)
          def __phoenix_macro_components__ do
            %{
              Phoenix.LiveView.ColocatedHook => [@__lavash_client_hook_data__]
            }
          end
        end

      optimistic_colocated_data ->
        quote do
          @__lavash_optimistic_colocated_data__ unquote(optimistic_colocated_data)
          def __phoenix_macro_components__ do
            %{
              Phoenix.LiveView.ColocatedJS => [@__lavash_optimistic_colocated_data__]
            }
          end
        end

      true ->
        quote do end
    end
  end

  @doc """
  Generate render/1 function from macro-based render definitions.

  Syntax: `render fn assigns -> ~L\"\"\"...\"\"\" end`
  """
  def generate_render_from_macros(renders, env) do
    renders_map = Map.new(renders)

    case Map.get(renders_map, :__render_fn__) do
      nil ->
        quote do end

      escaped_fn ->
        client_hook_name =
          Spark.Dsl.Extension.get_persisted(env.module, :lavash_client_hook_name)

        if client_hook_name do
          generate_render_with_client_hook(escaped_fn, client_hook_name)
        else
          generate_render_from_fn(escaped_fn)
        end
    end
  end

  # Simple render — no client hook, just call the function
  defp generate_render_from_fn(escaped_fn) do
    quote do
      @impl Phoenix.LiveComponent
      def render(var!(assigns)) do
        render_fn = unquote(escaped_fn)
        render_fn.(var!(assigns))
      end
    end
  end

  # Render with client hook wrapper — serializes state and wraps in hook root div
  defp generate_render_with_client_hook(escaped_fn, hook_name) do
    quote do
      @impl Phoenix.LiveComponent
      def render(var!(assigns)) do
        state = Lavash.Component.Compiler.build_client_state(__MODULE__, var!(assigns))
        state_json = Jason.encode!(state)
        bindings_json = Jason.encode!(Map.get(var!(assigns), :__lavash_binding_map__, %{}))
        version = Map.get(var!(assigns), :__lavash_version__, 0)

        var!(assigns) =
          var!(assigns)
          |> Phoenix.Component.assign(:__state_json__, state_json)
          |> Phoenix.Component.assign(:__bindings_json__, bindings_json)
          |> Phoenix.Component.assign(:__hook_name__, unquote(hook_name))
          |> Phoenix.Component.assign(:__version__, version)
          |> Phoenix.Component.assign(state)

        render_fn = unquote(escaped_fn)
        inner = render_fn.(var!(assigns))

        Lavash.Component.HookWrapper.wrap(var!(assigns), inner)
      end
    end
  end


  @doc false
  def build_client_state(module, assigns) do
    # Collect optimistic state fields
    state_fields =
      if function_exported?(module, :__lavash__, 1) do
        module.__lavash__(:optimistic_fields)
      else
        []
      end

    state_map =
      Enum.reduce(state_fields, %{}, fn field, acc ->
        Map.put(acc, field.name, Map.get(assigns, field.name))
      end)

    # Collect props
    props =
      if function_exported?(module, :__lavash__, 1) do
        module.__lavash__(:props)
      else
        []
      end

    Enum.reduce(props, state_map, fn prop, acc ->
      value = Map.get(assigns, prop.name, prop.default)
      Map.put(acc, prop.name, value)
    end)
  end

end
