defmodule Lavash.LiveView.Compiler do
  @moduledoc """
  Compiles the Lavash DSL into LiveView callbacks.
  """

  defmacro __before_compile__(env) do
    has_on_mount = Module.defines?(env.module, {:on_mount, 1})
    has_render = Module.defines?(env.module, {:render, 1})

    # Get optimistic colocated data if available (persisted by ColocatedTransformer)
    # Escape immediately to avoid "tried to unquote invalid AST" errors during incremental compilation
    optimistic_colocated_data =
      case Spark.Dsl.Extension.get_persisted(env.module, :lavash_optimistic_colocated_data) do
        nil -> nil
        data -> Macro.escape(data)
      end

    # Check for render definitions from the macro-based approach
    lavash_renders = Module.get_attribute(env.module, :__lavash_renders__) || []

    # Determine render source from macro-based renders
    render_template =
      case lavash_renders do
        [] ->
          nil

        renders ->
          renders_map = Map.new(renders)

          # Check for function-based render - function AST is escaped
          Map.get(renders_map, :__render_fn__)
      end

    # Error if both render macro and render/1 are defined
    if render_template && has_render do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: """
        Cannot define both `render fn assigns ->` macro and `render/1` in the same LiveView.

        When using the `render` macro, the framework generates the render/1 function automatically.
        Remove your `def render(assigns)` function, or remove the `render fn assigns -> ... end` macro.
        """
    end

    mount_callback =
      if has_on_mount do
        quote do
          @impl Phoenix.LiveView
          def mount(params, session, socket) do
            {:ok, socket} = Lavash.LiveView.Runtime.mount(__MODULE__, params, session, socket)
            on_mount(socket)
          end
        end
      else
        quote do
          @impl Phoenix.LiveView
          def mount(params, session, socket) do
            Lavash.LiveView.Runtime.mount(__MODULE__, params, session, socket)
          end
        end
      end

    # Generate render from render macro, or wrap user-defined render
    render_code =
      cond do
        render_template ->
          # Generate render/1 from render template
          generate_render_from_template(render_template, env)

        has_render ->
          # Wrap user-defined render with optimistic state
          quote do
            defoverridable render: 1

            @impl Phoenix.LiveView
            def render(assigns) do
              inner_content = super(assigns)
              Lavash.LiveView.Runtime.wrap_render(__MODULE__, assigns, inner_content)
            end
          end

        true ->
          quote do
          end
      end

    quote do
      unquote(mount_callback)
      unquote(render_code)

      @impl Phoenix.LiveView
      def handle_params(params, uri, socket) do
        Lavash.LiveView.Runtime.handle_params(__MODULE__, params, uri, socket)
      end

      @impl Phoenix.LiveView
      def handle_event(event, params, socket) do
        Lavash.LiveView.Runtime.handle_event(__MODULE__, event, params, socket)
      end

      @impl Phoenix.LiveView
      def handle_info(msg, socket) do
        Lavash.LiveView.Runtime.handle_info(__MODULE__, msg, socket)
      end

      # Introspection functions - entities from top_level? sections
      def __lavash__(:states) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:states])
      end

      def __lavash__(:reads) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:reads])
      end

      def __lavash__(:forms) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:forms])
      end

      def __lavash__(:extend_errors) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:extend_errors_declarations])
      end

      def __lavash__(:actions) do
        # TODO: Move action generation to a compile-time transformer instead of runtime generation.
        #
        # Currently this function dynamically generates actions on every call. A better approach
        # would be to use a Spark transformer (e.g., Lavash.Transformers.GenerateActions) that:
        # - Runs at compile time during DSL processing
        # - Adds generated actions as entities to [:actions] path using Transformer.add_entity
        # - Eliminates runtime overhead of repeated generation
        #
        # See Lavash.Overlay.Modal.Transformers.InjectState for a similar pattern.
        #
        # Challenges:
        # - Optimistic actions use Code.eval_quoted to create callable functions (line 369 below)
        # - This runtime evaluation would need to be preserved or refactored
        declared_actions = Spark.Dsl.Extension.get_entities(__MODULE__, [:actions])
        setter_actions = Lavash.LiveView.Compiler.generate_setter_actions(__MODULE__)
        optimistic_actions = Lavash.LiveView.Compiler.generate_optimistic_actions(__MODULE__)
        declared_actions ++ setter_actions ++ optimistic_actions
      end

      # Convenience accessors by storage type
      def __lavash__(:url_fields) do
        __lavash__(:states) |> Enum.filter(&(&1.from == :url))
      end

      def __lavash__(:socket_fields) do
        __lavash__(:states) |> Enum.filter(&(&1.from == :socket))
      end

      def __lavash__(:ephemeral_fields) do
        __lavash__(:states) |> Enum.filter(&(is_nil(&1.from) || &1.from == :ephemeral))
      end

      def __lavash__(:optimistic_fields) do
        states = __lavash__(:states)
        explicitly_optimistic = Enum.filter(states, &Lavash.State.Field.optimistic?/1)

        # Auto-detect: fields touched by transpilable actions are implicitly optimistic
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

        # Add fields touched by actions that aren't already explicitly optimistic
        explicit_names = MapSet.new(explicitly_optimistic, & &1.name)
        auto_optimistic =
          states
          |> Enum.filter(fn f -> f.name in action_touched_fields and f.name not in explicit_names end)

        explicitly_optimistic ++ auto_optimistic
      end

      def __lavash__(:optimistic_derives) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:derives])
        |> Enum.filter(&(Map.get(&1, :optimistic, false) == true))
      end

      # Expose calculations for JsGenerator
      # Returns 7-tuples from Spark DSL entities: {name, source, ast, deps, optimistic, async, reads}
      def __lavash_calculations__ do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:calculations])
        |> Enum.map(fn calc ->
          {calc.name, calc.rx.source, calc.rx.ast, calc.rx.deps,
           Map.get(calc, :optimistic, true),
           Map.get(calc, :async, false),
           Map.get(calc, :reads, [])}
        end)
      end

      # Expose optimistic actions from the optimistic_action macro
      def __lavash_optimistic_actions__ do
        @__lavash_optimistic_actions__ || []
      end

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

  # ============================================
  # Render function generation
  # ============================================

  @doc """
  Generate render/1 function from render function macro.

  Handles `render fn assigns -> ~L\"\"\"...\"\"\" end` (function-based render macro).

  This wraps the template output with optimistic state handling.
  """
  def generate_render_from_template(escaped_fn, _env) do
    # Function-based render - function AST was escaped by RenderMacro
    # Inject the function directly into the render definition
    quote do
      @impl Phoenix.LiveView
      def render(var!(assigns)) do
        # Call the user's render function (injected at compile time)
        render_fn = unquote(escaped_fn)
        inner_content = render_fn.(var!(assigns))

        # Wrap with optimistic state
        Lavash.LiveView.Runtime.wrap_render(__MODULE__, var!(assigns), inner_content)
      end
    end
  end

  @doc """
  Generate synthetic setter actions for state fields with setter: true or optimistic: true.
  Optimistic fields automatically get setters to enable client-side optimistic updates.
  """
  def generate_setter_actions(module) do
    module.__lavash__(:states)
    |> Enum.filter(fn
      %Lavash.State.Field{} = f -> f.setter || Lavash.State.Field.optimistic?(f)
      _ -> false
    end)
    |> Enum.map(fn state ->
      %Lavash.Actions.Action{
        name: :"set_#{state.name}",
        params: [:value],
        when: [],
        sets: [
          %Lavash.Actions.Set{
            field: state.name,
            value: & &1.params.value
          }
        ],
        updates: [],
        effects: [],
        submits: [],
        navigates: [],
        flashes: [],
        invokes: []
      }
    end)
  end


  @doc """
  Generate actions from optimistic_action macro definitions.

  Each optimistic_action is converted to a Lavash.Actions.Action with an update
  that applies the run function. This allows optimistic_action to be used in LiveViews
  just like in components.

  ## Example

      optimistic_action :add_tag, :tags,
        run: fn tags, tag -> tags ++ [tag] end,
        validate: fn tags, tag -> tag not in tags end

  Generates an action equivalent to:

      action :add_tag, params: [:value] do
        update :tags, fn current -> run_fn.(current, params.value) end
      end

  ## Why Separate from Spark DSL Actions?

  The `optimistic_action` macro exists separately from Spark's `action` DSL because it needs
  to capture SOURCE CODE at compile time for JavaScript transpilation. The Spark DSL `action`
  entity uses runtime function references which cannot be transpiled to JavaScript.

  The `run_fn` referenced in the generated action is parsed from `run_source` (the function
  source code captured by `Macro.to_string` in the `optimistic_action` macro). See
  `Lavash.Optimistic.Macros` for the macro implementation and `Lavash.Optimistic.JsGenerator`
  for JavaScript generation.

  These optimistic actions are merged with declared actions in `__lavash__(:actions)`.
  """
  def generate_optimistic_actions(module) do
    if function_exported?(module, :__lavash_optimistic_actions__, 0) do
      module.__lavash_optimistic_actions__()
      |> Enum.map(fn {name, field, run_source, _validate_source, _max} ->
        # Parse the run function from source
        run_fn =
          case Code.string_to_quoted(run_source) do
            {:ok, ast} ->
              {fun, _} = Code.eval_quoted(ast)
              fun

            _ ->
              fn current, _value -> current end
          end

        # Create an action with an update step
        %Lavash.Actions.Action{
          name: name,
          params: [:value],
          when: [],
          sets: [],
          updates: [
            %Lavash.Actions.Update{
              field: field,
              # The update function calls the parsed run_fn with current value and params.value
              fun: fn current, context ->
                value = Map.get(context.params, :value)
                run_fn.(current, value)
              end
            }
          ],
          effects: [],
          submits: [],
          navigates: [],
          flashes: [],
          invokes: []
        }
      end)
    else
      []
    end
  end

end
