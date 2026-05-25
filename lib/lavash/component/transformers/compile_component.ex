defmodule Lavash.Component.Transformers.CompileComponent do
  @moduledoc """
  Compiles component template and generates all LiveComponent callbacks.

  Reads pre-tokenized template tokens from `:lavash_template_tokens` and
  compiles them to `%Rendered{}` AST via `TagEngine.compile_from_tokens`.
  Generates `render/1`, `update/2`, `handle_event/2`, introspection functions,
  and `__phoenix_macro_components__/0` via `Transformer.eval`.

  This is the final transformer in the component pipeline — it runs after
  all analysis and JS generation is complete.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  # Run after everything else
  def after?(_), do: true
  def before?(_), do: false

  def transform(dsl_state) do
    env = Transformer.get_persisted(dsl_state, :env)

    if is_nil(env) do
      {:ok, dsl_state}
    else
      # Only compile for Lavash.Component modules
      is_component = Module.get_attribute(env.module, :__lavash_module_type__) == :component

      if is_component do
        {:ok, generate_component_code(dsl_state, env)}
      else
        {:ok, dsl_state}
      end
    end
  end

  defp generate_component_code(dsl_state, env) do
    render_generator = Transformer.get_persisted(dsl_state, :lavash_overlay_render_generator)
    lavash_renders = Module.get_attribute(env.module, :__lavash_renders__) || []

    has_optimistic =
      Transformer.get_persisted(dsl_state, :lavash_optimistic_colocated_data) != nil

    # Build render function AST
    render_ast =
      build_render_ast(render_generator, lavash_renders, has_optimistic, env, dsl_state)

    # Build external_resource AST for overlay helpers recompilation tracking
    external_resource_ast =
      if render_generator do
        helpers_path = render_generator.helpers_path()
        quote do: @external_resource(unquote(helpers_path))
      else
        quote do: nil
      end

    # Build __phoenix_macro_components__ AST
    colocated_ast = build_colocated_ast(dsl_state)

    introspection_ast = build_lavash_introspection_ast()
    run_refs_ast = build_run_refs_ast(dsl_state)
    calc_refs_ast = build_calc_refs_ast(dsl_state)

    Transformer.eval(
      dsl_state,
      [],
      quote do
        unquote(external_resource_ast)

        @impl Phoenix.LiveComponent
        def update(assigns, socket) do
          Lavash.Component.Runtime.update(__MODULE__, assigns, socket)
        end

        @impl Phoenix.LiveComponent
        def handle_event(event, params, socket) do
          Lavash.Component.Runtime.handle_event(__MODULE__, event, params, socket)
        end

        defoverridable update: 2, handle_event: 3

        @after_compile {Lavash.Dsl.Graph, :erase}
        @after_compile {Lavash.Reactive, :erase_graph}
        @after_compile {Lavash.Rx.Cache, :erase}

        unquote(render_ast)
        unquote(introspection_ast)
        unquote(colocated_ast)
        unquote(run_refs_ast)
        unquote(calc_refs_ast)
      end
    )
  end

  # See `Lavash.LiveView.Transformers.CompileLiveView.build_run_refs_ast/1`
  # for the rationale: emit a `__lavash_run__/3` clause per (action, run-index)
  # pair so the body executes in the user's module scope (helpers visible,
  # compiler tracks references, no `:erl_eval`).
  defp build_run_refs_ast(dsl_state) do
    actions = Transformer.get_entities(dsl_state, [:actions]) || []

    clauses =
      Enum.flat_map(actions, fn action ->
        (action.runs || [])
        |> Enum.with_index()
        |> Enum.map(fn {run, idx} ->
          name = action.name

          quote do
            @doc false
            def __lavash_run__(unquote(name), unquote(idx), var!(assigns)) do
              import Phoenix.Component, only: [assign: 3]
              unquote(run.fun).(var!(assigns))
            end
          end
        end)
      end)

    if clauses == [] do
      quote do
      end
    else
      quote do
        (unquote_splicing(clauses))
      end
    end
  end

  # See `Lavash.LiveView.Transformers.CompileLiveView.build_calc_refs_ast/1`
  # for the rationale: emit a `__lavash_calc__/2` clause per `calculate`
  # so the rx body executes in the user's module scope.
  defp build_calc_refs_ast(dsl_state) do
    calculations = Transformer.get_entities(dsl_state, [:calculations]) || []
    module = Transformer.get_persisted(dsl_state, :module)
    state_var = Macro.var(:state, nil)

    clauses =
      Enum.map(calculations, fn calc ->
        name = calc.name
        ast = unqualify_self_calls(calc.rx.ast, module)

        quote do
          @doc false
          def __lavash_calc__(unquote(name), unquote(state_var)) do
            _ = unquote(state_var)
            unquote(ast)
          end
        end
      end)

    if clauses == [] do
      quote do
      end
    else
      quote do
        (unquote_splicing(clauses))
      end
    end
  end

  defp unqualify_self_calls(ast, self_module) do
    Macro.prewalk(ast, fn
      {{:., _dot_meta, [^self_module, fun]}, call_meta, args}
      when is_atom(fun) and is_list(args) ->
        {fun, call_meta, args}

      node ->
        node
    end)
  end

  defp build_lavash_introspection_ast do
    quote do
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

      def __lavash_calculations__ do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:calculations])
        |> Enum.map(fn calc ->
          {calc.name, calc.rx.source, calc.rx.ast, calc.rx.deps, Map.get(calc, :optimistic, true),
           Map.get(calc, :async, false), Map.get(calc, :reads, [])}
        end)
      end

      def __lavash__(:actions) do
        declared = __lavash__(:declared_actions)
        setter_actions = Lavash.LiveView.Compiler.generate_setter_actions(__MODULE__)
        declared ++ setter_actions
      end

      # The user-declared `action ... end` entities, unaugmented by the
      # synthetic setter actions that __lavash__(:actions) adds.
      def __lavash__(:declared_actions) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:actions]) || []
      end

      def __lavash__(:socket_fields) do
        __lavash__(:states) |> Enum.filter(&(&1.from == :socket))
      end

      def __lavash__(:ephemeral_fields) do
        __lavash__(:states) |> Enum.filter(&(&1.from == :ephemeral))
      end

      def __lavash__(:optimistic_fields) do
        Lavash.LiveView.Compiler.collect_optimistic_fields(__MODULE__)
      end

      def __lavash__(:url_fields), do: []
    end
  end

  # ============================================
  # Render AST generation
  # ============================================

  defp build_render_ast(render_generator, lavash_renders, has_optimistic, env, dsl_state) do
    cond do
      render_generator ->
        render_generator.generate(env.module, dsl_state)

      lavash_renders != [] ->
        build_render_from_macros(lavash_renders, has_optimistic, env, dsl_state)

      true ->
        quote do
        end
    end
  end

  defp build_render_from_macros(renders, has_optimistic, env, dsl_state) do
    renders_map = Map.new(renders)

    case Map.get(renders_map, :__render_fn__) do
      nil ->
        quote do
        end

      _escaped_fn ->
        pre_tokens = Transformer.get_persisted(dsl_state, :lavash_template_tokens)
        template_source = Transformer.get_persisted(dsl_state, :lavash_template_source)

        compiled_ast = compile_template_from_tokens(pre_tokens, template_source, env, dsl_state)

        if has_optimistic do
          build_render_with_compiled_template(compiled_ast, env.module)
        else
          build_simple_render_with_compiled_template(compiled_ast)
        end
    end
  end

  # ============================================
  # Template compilation from pre-tokenized tokens
  # ============================================

  defp compile_template_from_tokens(tokens, source, env, dsl_state) do
    metadata = build_token_transformer_metadata_from_dsl(env, dsl_state)

    opts = [
      file: env.file,
      line: 1,
      caller: env,
      source: source,
      tag_handler: Phoenix.LiveView.HTMLEngine,
      token_transformer: Lavash.Template.TokenTransformer,
      lavash_metadata: metadata
    ]

    Lavash.TagEngine.compile_from_tokens(tokens, opts)
  end

  @doc false
  def build_token_transformer_metadata_from_dsl(env, dsl_state) do
    module_type = Module.get_attribute(env.module, :__lavash_module_type__)
    context = module_type || :live_view

    states = Transformer.get_entities(dsl_state, [:states]) || []
    forms = Transformer.get_entities(dsl_state, [:forms]) || []
    actions = Transformer.get_entities(dsl_state, [:actions]) || []
    calculations = Transformer.get_entities(dsl_state, [:calculations]) || []

    optimistic_fields =
      states
      |> Enum.filter(fn
        %Lavash.State.Field{} = f -> Lavash.State.Field.optimistic?(f)
        _ -> false
      end)
      |> Enum.map(fn %Lavash.State.Field{name: name} = field -> {name, field} end)
      |> Map.new()

    implicit_form_fields =
      forms
      |> Enum.flat_map(fn form ->
        [
          {:"#{form.name}_params",
           %{name: :"#{form.name}_params", type: :map, optimistic: true, from: :ephemeral}},
          {:"#{form.name}_server_errors",
           %{name: :"#{form.name}_server_errors", type: :map, optimistic: true, from: :ephemeral}}
        ]
      end)
      |> Map.new()

    optimistic_fields = Map.merge(optimistic_fields, implicit_form_fields)

    # All declared state fields (including non-optimistic ones). Used by the
    # token transformer to diagnose `{@field}` references in `~L` where the
    # field is declared but not optimistic — likely a user mistake.
    all_state_fields =
      states
      |> Enum.map(fn
        %Lavash.State.Field{name: name} = field -> {name, field}
        other -> {Map.get(other, :name), other}
      end)
      |> Enum.reject(fn {name, _} -> is_nil(name) end)
      |> Map.new()

    forms_map =
      forms
      |> Enum.map(fn form ->
        fields =
          try do
            if Code.ensure_loaded?(form.resource) and
                 function_exported?(form.resource, :spark_dsl_config, 0) do
              Ash.Resource.Info.attributes(form.resource) |> Enum.map(& &1.name)
            else
              []
            end
          rescue
            _ -> []
          end

        {form.name, %{resource: form.resource, fields: fields}}
      end)
      |> Map.new()

    actions_map = actions |> Enum.map(fn a -> {a.name, a} end) |> Map.new()

    optimistic_actions_map =
      actions
      |> Enum.filter(&Lavash.Optimistic.ActionJs.action_is_optimistic?/1)
      |> Enum.flat_map(fn action ->
        (action.sets || []) |> Enum.map(fn set -> {action.name, %{field: set.field}} end)
      end)
      |> Map.new()

    form_valid_fields =
      forms
      |> Enum.flat_map(fn form -> [{:"#{form.name}_valid", %{optimistic: true}}] end)
      |> Map.new()

    calc_map =
      calculations
      |> Enum.filter(&Map.get(&1, :optimistic, true))
      |> Enum.map(fn calc -> {calc.name, %{optimistic: true}} end)
      |> Map.new()
      |> Map.merge(form_valid_fields)

    attr_derives = Transformer.get_persisted(dsl_state, :lavash_attr_derives) || []

    %{
      context: context,
      optimistic_fields: optimistic_fields,
      all_state_fields: all_state_fields,
      calculations: calc_map,
      forms: forms_map,
      actions: actions_map,
      optimistic_actions: optimistic_actions_map,
      attr_derives: attr_derives,
      caller_module: env.module,
      caller_file: env.file
    }
  end

  # ============================================
  # Render function builders
  # ============================================

  defp build_render_with_compiled_template(compiled_ast, module) do
    module_name = inspect(module)

    quote do
      @impl Phoenix.LiveComponent
      def render(var!(assigns)) do
        state = Lavash.Component.Compiler.build_client_state(__MODULE__, var!(assigns))
        state_json = Jason.encode!(state)
        bindings_json = Jason.encode!(Map.get(var!(assigns), :__lavash_client_bindings__, %{}))
        version = Map.get(var!(assigns), :__lavash_version__, 0)

        var!(assigns) =
          var!(assigns)
          |> Phoenix.Component.assign(:__state_json__, state_json)
          |> Phoenix.Component.assign(:__bindings_json__, bindings_json)
          |> Phoenix.Component.assign(:__module_name__, unquote(module_name))
          |> Phoenix.Component.assign(:__version__, version)
          |> Phoenix.Component.assign(state)

        inner = unquote(compiled_ast)

        Lavash.Component.OptimisticWrapper.wrap(var!(assigns), inner)
      end
    end
  end

  defp build_simple_render_with_compiled_template(compiled_ast) do
    quote do
      @impl Phoenix.LiveComponent
      def render(var!(assigns)) do
        unquote(compiled_ast)
      end
    end
  end

  defp build_colocated_ast(dsl_state) do
    case Transformer.get_persisted(dsl_state, :lavash_optimistic_colocated_data) do
      nil ->
        quote do
        end

      data ->
        escaped_data = Macro.escape(data)

        quote do
          @__lavash_optimistic_colocated_data__ unquote(escaped_data)
          def __phoenix_macro_components__ do
            %{
              Phoenix.LiveView.ColocatedJS => [@__lavash_optimistic_colocated_data__]
            }
          end
        end
    end
  end
end
