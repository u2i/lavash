defmodule Lavash.LiveView.Compiler do
  @moduledoc """
  Compiles the Lavash DSL into LiveView callbacks.
  """

  defmacro __before_compile__(env) do
    has_on_mount = Module.defines?(env.module, {:on_mount, 1})
    has_render = Module.defines?(env.module, {:render, 1})

    # Get optimistic colocated data if available (persisted by ColocatedTransformer)
    optimistic_colocated_data =
      Spark.Dsl.Extension.get_persisted(env.module, :lavash_optimistic_colocated_data)

    # Check for template DSL entity
    templates = Spark.Dsl.Extension.get_entities(env.module, [:template_section]) || []

    template_source =
      case templates do
        [%{source: source} | _] -> source
        _ -> nil
      end

    # Error if both template DSL and render/1 are defined
    if template_source && has_render do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: """
        Cannot define both `template` and `render/1` in the same LiveView.

        When using the `template` DSL, the framework generates the render/1 function automatically.
        Remove your `def render(assigns)` function, or use `~L` sigil inside render/1 instead of the `template` DSL.
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

    # Generate render from template DSL, or wrap user-defined render
    render_code =
      cond do
        template_source ->
          # Generate render/1 from template DSL
          generate_render_from_template(template_source, env)

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
      # Note: This returns StateField structs, including synthetic ones from multi_select/toggle
      def __lavash__(:states) do
        explicit_states = Spark.Dsl.Extension.get_entities(__MODULE__, [:states])
                          |> Enum.filter(&match?(%Lavash.StateField{}, &1))

        multi_select_states = Lavash.LiveView.Compiler.generate_multi_select_states(__MODULE__)
        toggle_states = Lavash.LiveView.Compiler.generate_toggle_states(__MODULE__)

        explicit_states ++ multi_select_states ++ toggle_states
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

      def __lavash__(:derived_fields) do
        explicit_derives = Spark.Dsl.Extension.get_entities(__MODULE__, [:derives])
                           |> Enum.map(&Lavash.LiveView.Compiler.normalize_derived/1)

        multi_select_derives = Lavash.LiveView.Compiler.generate_multi_select_derives(__MODULE__)
        toggle_derives = Lavash.LiveView.Compiler.generate_toggle_derives(__MODULE__)

        explicit_derives ++ multi_select_derives ++ toggle_derives
      end

      def __lavash__(:actions) do
        declared_actions = Spark.Dsl.Extension.get_entities(__MODULE__, [:actions])
        setter_actions = Lavash.LiveView.Compiler.generate_setter_actions(__MODULE__)
        multi_select_actions = Lavash.LiveView.Compiler.generate_multi_select_actions(__MODULE__)
        toggle_actions = Lavash.LiveView.Compiler.generate_toggle_actions(__MODULE__)
        optimistic_actions = Lavash.LiveView.Compiler.generate_optimistic_actions(__MODULE__)
        declared_actions ++ setter_actions ++ multi_select_actions ++ toggle_actions ++ optimistic_actions
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
        __lavash__(:states) |> Enum.filter(&(&1.optimistic == true))
      end

      def __lavash__(:optimistic_derives) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:derives])
        |> Enum.filter(&(Map.get(&1, :optimistic, false) == true))
      end

      # Multi-select and Toggle introspection
      def __lavash__(:multi_selects) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:states])
        |> Enum.filter(&match?(%Lavash.MultiSelect{}, &1))
      end

      def __lavash__(:toggles) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:states])
        |> Enum.filter(&match?(%Lavash.Toggle{}, &1))
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
        @__lavash_optimistic_colocated_data__ unquote(Macro.escape(optimistic_colocated_data))
        def __phoenix_macro_components__ do
          %{
            Phoenix.LiveView.ColocatedJS => [@__lavash_optimistic_colocated_data__]
          }
        end
      end
    end
  end

  # ============================================
  # Template rendering from DSL
  # ============================================

  @doc """
  Generate render/1 function from template DSL.

  This transforms the template with Lavash.Template.Transformer to inject
  data-lavash-* attributes, then compiles the HEEx and wraps the result
  with optimistic state handling.
  """
  def generate_render_from_template(template_source, env) do
    module = env.module

    # Get metadata for template transformation
    metadata = Lavash.Sigil.get_compile_time_metadata(module)

    # Transform template to inject data-lavash-* attributes
    transformed_template =
      if metadata do
        Lavash.Template.Transformer.transform(template_source, module, metadata: metadata)
      else
        template_source
      end

    quote do
      # Store the transformed template source for the render macro
      @__lavash_template_source__ unquote(transformed_template)

      @doc false
      defmacro __lavash_render_template__(assigns_var) do
        template = Module.get_attribute(__MODULE__, :__lavash_template_source__)

        opts = [
          engine: Phoenix.LiveView.TagEngine,
          caller: __CALLER__,
          source: template,
          tag_handler: Phoenix.LiveView.HTMLEngine
        ]

        ast = EEx.compile_string(template, opts)

        quote do
          var!(assigns) = unquote(assigns_var)
          unquote(ast)
        end
      end

      @impl Phoenix.LiveView
      def render(var!(assigns)) do
        # Render the template
        inner_content = __lavash_render_template__(var!(assigns))

        # Wrap with optimistic state (same as user-defined render)
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
    |> Enum.filter(&(&1.setter || &1.optimistic))
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
  Generate synthetic toggle actions for multi_select fields.
  Each multi_select gets a toggle_<name> action that adds/removes values from the array.
  """
  def generate_multi_select_actions(module) do
    module.__lavash__(:multi_selects)
    |> Enum.map(fn ms ->
      field_name = ms.name

      %Lavash.Actions.Action{
        name: :"toggle_#{ms.name}",
        params: [:val],
        when: [],
        sets: [
          %Lavash.Actions.Set{
            field: field_name,
            value: &toggle_in_list(Map.get(&1.state, field_name) || [], &1.params.val)
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
  Generate synthetic toggle actions for toggle fields.
  Each toggle gets a toggle_<name> action that flips the boolean.
  """
  def generate_toggle_actions(module) do
    module.__lavash__(:toggles)
    |> Enum.map(fn toggle ->
      field_name = toggle.name

      %Lavash.Actions.Action{
        name: :"toggle_#{toggle.name}",
        params: [],
        when: [],
        sets: [],
        updates: [
          %Lavash.Actions.Update{
            field: field_name,
            fun: &(not &1)
          }
        ],
        effects: [],
        submits: [],
        navigates: [],
        flashes: [],
        invokes: []
      }
    end)
  end

  defp toggle_in_list(list, value) when value in ["", nil], do: list

  defp toggle_in_list(list, value) do
    if value in list do
      List.delete(list, value)
    else
      [value | list]
    end
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

  # ============================================
  # State generation for multi_select and toggle
  # ============================================

  @doc """
  Generate synthetic state fields for multi_select declarations.
  """
  def generate_multi_select_states(module) do
    module.__lavash__(:multi_selects)
    |> Enum.map(fn ms ->
      %Lavash.StateField{
        name: ms.name,
        type: {:array, :string},
        from: ms.from,
        default: ms.default || [],
        optimistic: true
      }
    end)
  end

  @doc """
  Generate synthetic state fields for toggle declarations.
  """
  def generate_toggle_states(module) do
    module.__lavash__(:toggles)
    |> Enum.map(fn toggle ->
      %Lavash.StateField{
        name: toggle.name,
        type: :boolean,
        from: toggle.from,
        default: toggle.default || false,
        optimistic: true
      }
    end)
  end

  # ============================================
  # Derive generation for multi_select and toggle
  # ============================================

  @default_chip_class [
    base: "px-3 py-1.5 text-sm rounded-full border transition-colors cursor-pointer",
    active: "bg-primary text-primary-content border-primary",
    inactive: "bg-base-100 text-base-content/70 border-base-300 hover:border-primary/50"
  ]

  @doc """
  Generate synthetic chip derives for multi_select declarations.
  Each multi_select gets a <name>_chips derive that computes CSS classes.
  """
  def generate_multi_select_derives(module) do
    module.__lavash__(:multi_selects)
    |> Enum.map(fn ms ->
      field_name = ms.name
      values = ms.values
      chip_class = ms.chip_class || @default_chip_class

      base = Keyword.get(chip_class, :base, "")
      active = Keyword.get(chip_class, :active, "")
      inactive = Keyword.get(chip_class, :inactive, "")

      active_class = String.trim("#{base} #{active}")
      inactive_class = String.trim("#{base} #{inactive}")

      %Lavash.Derived.Field{
        name: :"#{ms.name}_chips",
        async: false,
        optimistic: true,
        depends_on: [field_name],
        compute: fn deps ->
          selected = Map.get(deps, field_name) || []
          Map.new(values, fn value ->
            class = if value in selected, do: active_class, else: inactive_class
            {value, class}
          end)
        end
      }
    end)
  end

  @doc """
  Generate synthetic chip derives for toggle declarations.
  Each toggle gets a <name>_chip derive that computes the CSS class.
  """
  def generate_toggle_derives(module) do
    module.__lavash__(:toggles)
    |> Enum.map(fn toggle ->
      field_name = toggle.name
      chip_class = toggle.chip_class || @default_chip_class

      base = Keyword.get(chip_class, :base, "")
      active = Keyword.get(chip_class, :active, "")
      inactive = Keyword.get(chip_class, :inactive, "")

      active_class = String.trim("#{base} #{active}")
      inactive_class = String.trim("#{base} #{inactive}")

      %Lavash.Derived.Field{
        name: :"#{toggle.name}_chip",
        async: false,
        optimistic: true,
        depends_on: [field_name],
        compute: fn deps ->
          active = Map.get(deps, field_name)
          if active, do: active_class, else: inactive_class
        end
      }
    end)
  end

  @doc """
  Normalize a derived field - extract depends_on from arguments and wrap run into compute.
  """
  def normalize_derived(%Lavash.Derived.Field{} = field) do
    # Extract depends_on from arguments
    # If source is nil, default to state(arg_name)
    depends_on =
      (field.arguments || [])
      |> Enum.map(fn arg ->
        extract_source_field(arg.source, arg.name)
      end)

    # Build arg name mapping for the compute wrapper
    # Each entry is {arg_name, source_field, transform}
    arg_mapping =
      (field.arguments || [])
      |> Enum.map(fn arg ->
        source_field = extract_source_field(arg.source, arg.name)
        {arg.name, source_field, arg.transform}
      end)

    # Create compute wrapper that maps state to argument names
    compute =
      if field.run do
        fn deps ->
          # Map the deps to use argument names, applying transforms
          mapped_deps =
            Enum.reduce(arg_mapping, %{}, fn {arg_name, source_field, transform}, acc ->
              value = Map.get(deps, source_field)
              value = if transform, do: transform.(value), else: value
              Map.put(acc, arg_name, value)
            end)

          # Call run with mapped deps and empty context
          field.run.(mapped_deps, %{})
        end
      else
        field.compute
      end

    %{field | depends_on: depends_on, compute: compute}
  end

  # Extract the source field name from source tuple, defaulting to state(arg_name) if nil
  defp extract_source_field(source, arg_name) do
    case source do
      {:state, name} -> name
      {:result, name} -> name
      {:prop, name} -> name
      name when is_atom(name) and not is_nil(name) -> name
      # Default to same-named state field
      nil -> arg_name
    end
  end
end
