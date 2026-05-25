defmodule Lavash.LiveView.Transformers.CompileLiveView do
  @moduledoc """
  Compiles LiveView template and generates all LiveView callbacks.

  Reads pre-tokenized template tokens from `:lavash_template_tokens` and
  compiles them to `%Rendered{}` AST via `TagEngine.compile_from_tokens`.
  Generates `mount/3`, `render/1`, `handle_params/3`, `handle_event/3`,
  `handle_info/2`, introspection functions, and `__phoenix_macro_components__/0`
  via `Transformer.eval`.

  This replaces `Lavash.LiveView.Compiler.__before_compile__`.
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
      # Only compile for Lavash.LiveView modules
      is_live_view = Module.get_attribute(env.module, :__lavash_module_type__) == :live_view

      if is_live_view do
        {:ok, generate_live_view_code(dsl_state, env)}
      else
        {:ok, dsl_state}
      end
    end
  end

  defp generate_live_view_code(dsl_state, env) do
    has_on_mount = Module.defines?(env.module, {:on_mount, 1})
    has_render = Module.defines?(env.module, {:render, 1})

    lavash_renders = Module.get_attribute(env.module, :__lavash_renders__) || []
    renders_map = Map.new(lavash_renders)
    render_template = Map.get(renders_map, :__render_fn__)

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

    mount_ast = build_mount_ast(has_on_mount)
    render_ast = build_render_ast(render_template, has_render, env, dsl_state)
    colocated_ast = build_colocated_ast(dsl_state)
    callbacks_ast = build_callbacks_ast()
    lavash_introspection_ast = build_lavash_introspection_ast()
    cache_invalidation_ast = build_cache_invalidation_ast()
    run_refs_ast = build_run_refs_ast(dsl_state)
    calc_refs_ast = build_calc_refs_ast(dsl_state)
    handle_info_ast = build_messages_ast(dsl_state)

    # `components do component ... end end` emits its function
    # defs directly at macro expansion time (see
    # Lavash.Components.ComponentsMacro). Nothing to do here.

    Transformer.eval(
      dsl_state,
      [],
      quote do
        unquote(mount_ast)
        unquote(render_ast)
        unquote(handle_info_ast)
        unquote(callbacks_ast)
        unquote(lavash_introspection_ast)
        unquote(cache_invalidation_ast)
        unquote(colocated_ast)
        unquote(run_refs_ast)
        unquote(calc_refs_ast)
      end
    )
  end

  # Emit declarative `messages do message <pattern> do <ops> end end`
  # clauses as real `def handle_info/2` heads. Each clause's body
  # is a list of ops (`run`/`effect`/`set`) that the compiled
  # def walks in order, threading the socket through.
  #
  # Layer 1: the body is a sequence of declarative ops. `set ...,
  # rx(...)` is layer 2 (reactive); `run` / `effect` are layer 1.
  # Reactive recompute happens AFTER the ops via the finalizer.
  defp build_messages_ast(dsl_state) do
    module = Transformer.get_persisted(dsl_state, :module)

    clauses = Module.get_attribute(module, :__lavash_messages__) || []

    if clauses == [] do
      quote do
      end
    else
      # Each clause is {:__message__, pattern_ast, bind_atoms, ops_list}.
      heads =
        Enum.map(clauses, fn {:__message__, pattern_ast, bind, ops} ->
          build_message_clause(pattern_ast, bind, ops)
        end)

      quote do
        @impl Phoenix.LiveView
        unquote_splicing(heads)
      end
    end
  end

  defp build_message_clause(pattern_ast, _bind, ops) do
    # The clause walks ops sequentially. Each op either mutates
    # `socket` (run, set) or runs a side effect (effect). After all
    # ops, we hand the touched-state list to the finalizer for
    # recompute + project.
    #
    # Imports are scoped to the def body so user `run fn socket ->`
    # bodies can call assign/3, push_event/3, etc. unqualified.

    op_statements = Enum.map(ops, &build_op_ast/1)

    touched =
      ops
      |> Enum.flat_map(fn
        {:set, field, _value} -> [field]
        _ -> []
      end)

    quote do
      def handle_info(unquote(pattern_ast), socket) do
        import Phoenix.LiveView,
          only: [
            push_event: 3,
            push_patch: 2,
            push_navigate: 2,
            redirect: 2,
            assign_async: 3,
            assign_async: 4,
            start_async: 3,
            start_async: 4,
            connected?: 1
          ]

        import Phoenix.Component, only: [assign: 2, assign: 3, update: 3]

        var!(socket) = Phoenix.Component.assign(socket, :__changed__, %{})

        unquote_splicing(op_statements)

        Lavash.Lifecycle.Runtime.finalize(__MODULE__, var!(socket), unquote(touched))
      end
    end
  end

  # `run fn socket -> ... end` — apply the lambda to the current
  # socket; the result becomes the new socket.
  defp build_op_ast({:run, fn_ast}) do
    quote do
      var!(socket) = unquote(fn_ast).(var!(socket))
    end
  end

  # `effect fn socket -> ... end` — call for side effects only.
  defp build_op_ast({:effect, fn_ast}) do
    quote do
      _ = unquote(fn_ast).(var!(socket))
    end
  end

  # `set :field, rx(...)` or `set :field, literal_value` — evaluate
  # via the action runtime's set-application machinery so it goes
  # through the same dirty/reactive-graph plumbing as inside an
  # action. The set struct is built at compile time; the runtime
  # call resolves rx values against current state.
  defp build_op_ast({:set, field, value_ast}) do
    quote do
      set = %Lavash.Actions.Set{field: unquote(field), value: unquote(value_ast)}

      var!(socket) =
        Lavash.Action.Runtime.apply_sets(var!(socket), [set], %{}, __MODULE__)
    end
  end

  # Emit one `__lavash_calc__/2` clause per `calculate :name, rx(...)` so the
  # rx body executes in the user module's scope. Same shape and rationale as
  # `__lavash_run__/3` above — both `def` and `defp` helpers resolve, and the
  # compiler tracks references inside the body so they don't warn as unused.
  # See u2i/lavash#18.
  defp build_calc_refs_ast(dsl_state) do
    calculations = Transformer.get_entities(dsl_state, [:calculations]) || []
    module = Transformer.get_persisted(dsl_state, :module)

    state_var = Macro.var(:state, nil)

    clauses =
      Enum.map(calculations, fn calc ->
        name = calc.name
        # The `rx()` macro pre-qualifies bare calls to `module.fun(...)` so
        # they work under `Code.eval_quoted` (where local resolution fails).
        # Inside the hoisted `__lavash_calc__/2` we're already in the user's
        # module, so strip the self-qualifier — that lets `defp` helpers
        # resolve (they're invisible to remote calls but visible to local).
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

  # `Mod.fun(args)` where Mod == self → `fun(args)`.
  defp unqualify_self_calls(ast, self_module) do
    Macro.prewalk(ast, fn
      {{:., dot_meta, [^self_module, fun]}, call_meta, args}
      when is_atom(fun) and is_list(args) ->
        _ = dot_meta
        {fun, call_meta, args}

      node ->
        node
    end)
  end

  # Emit one `__lavash_run__/3` clause per (action, run-index) pair so the
  # `run fn assigns -> ... end` body executes in the user module's scope.
  # The body is spliced into a real def, which means:
  #
  # 1. The compiler tracks every helper-function call inside the body
  #    (no more spurious "unused function" warnings — see u2i/lavash#11).
  # 2. Local function calls resolve at runtime (no more
  #    UndefinedFunctionError on unqualified `helper(assigns)` — see #15).
  # 3. Module attributes, aliases, and imports inside the user's module
  #    are in scope, just like any other function in that module.
  #
  # The runtime calls `module.__lavash_run__(action_name, idx, assigns)`
  # via `apply/3` (see `Lavash.Action.Runtime.apply_runs/5`).
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

  defp build_cache_invalidation_ast do
    quote do
      @after_compile {Lavash.Dsl.Graph, :erase}
      @after_compile {Lavash.Reactive, :erase_graph}
      @after_compile {Lavash.Rx.Cache, :erase}
    end
  end

  defp build_callbacks_ast do
    quote do
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

      defoverridable handle_params: 3, handle_event: 3, handle_info: 2
    end
  end

  defp build_lavash_introspection_ast do
    quote do
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
        declared = __lavash__(:declared_actions)
        setter_actions = Lavash.LiveView.Compiler.generate_setter_actions(__MODULE__)
        optimistic_actions = Lavash.LiveView.Compiler.generate_optimistic_actions(__MODULE__)
        declared ++ setter_actions ++ optimistic_actions
      end

      # The user-declared `action ... end` entities, unaugmented by the
      # synthetic setter/optimistic actions that __lavash__(:actions) adds.
      # Use this when generating the synthetic actions themselves so we don't
      # recurse, and for callers that genuinely need only the user's intent.
      def __lavash__(:declared_actions) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:actions]) || []
      end

      def __lavash__(:url_fields) do
        __lavash__(:states) |> Enum.filter(&(&1.from == :url))
      end

      def __lavash__(:socket_fields) do
        __lavash__(:states) |> Enum.filter(&(&1.from == :socket))
      end

      def __lavash__(:session_fields) do
        __lavash__(:states) |> Enum.filter(&(&1.from == :session))
      end

      def __lavash__(:ephemeral_fields) do
        __lavash__(:states) |> Enum.filter(&(is_nil(&1.from) || &1.from == :ephemeral))
      end

      def __lavash__(:optimistic_fields) do
        Lavash.LiveView.Compiler.collect_optimistic_fields(__MODULE__)
      end

      def __lavash_calculations__ do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:calculations])
        |> Enum.map(fn calc ->
          {calc.name, calc.rx.source, calc.rx.ast, calc.rx.deps, Map.get(calc, :optimistic, true),
           Map.get(calc, :async, false), Map.get(calc, :reads, [])}
        end)
      end

      def __lavash_optimistic_actions__ do
        @__lavash_optimistic_actions__ || []
      end
    end
  end

  # ============================================
  # Mount
  # ============================================

  defp build_mount_ast(has_on_mount) do
    if has_on_mount do
      quote do
        @impl Phoenix.LiveView
        def mount(params, session, socket) do
          {:ok, socket} = Lavash.LiveView.Runtime.mount(__MODULE__, params, session, socket)
          on_mount(socket)
        end

        defoverridable mount: 3
      end
    else
      quote do
        @impl Phoenix.LiveView
        def mount(params, session, socket) do
          Lavash.LiveView.Runtime.mount(__MODULE__, params, session, socket)
        end

        defoverridable mount: 3
      end
    end
  end

  # ============================================
  # Render
  # ============================================

  defp build_render_ast(render_template, has_render, env, dsl_state) do
    cond do
      render_template ->
        pre_tokens = Transformer.get_persisted(dsl_state, :lavash_template_tokens)
        template_source = Transformer.get_persisted(dsl_state, :lavash_template_source)
        compiled_ast = compile_template_from_tokens(pre_tokens, template_source, env, dsl_state)

        quote do
          @impl Phoenix.LiveView
          def render(var!(assigns)) do
            inner_content = unquote(compiled_ast)
            Lavash.LiveView.Runtime.wrap_render(__MODULE__, var!(assigns), inner_content)
          end
        end

      has_render ->
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
  end

  defp compile_template_from_tokens(tokens, source, env, dsl_state) do
    metadata =
      Lavash.Component.Transformers.CompileComponent.build_token_transformer_metadata_from_dsl(
        env,
        dsl_state
      )

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

  # ============================================
  # Colocated JS
  # ============================================

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
