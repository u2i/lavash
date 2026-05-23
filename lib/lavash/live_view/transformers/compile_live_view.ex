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

    Transformer.eval(
      dsl_state,
      [],
      quote do
        unquote(mount_ast)
        unquote(render_ast)

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
          declared_actions = Spark.Dsl.Extension.get_entities(__MODULE__, [:actions])
          setter_actions = Lavash.LiveView.Compiler.generate_setter_actions(__MODULE__)
          optimistic_actions = Lavash.LiveView.Compiler.generate_optimistic_actions(__MODULE__)
          declared_actions ++ setter_actions ++ optimistic_actions
        end

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
            |> Enum.filter(fn f ->
              f.name in action_touched_fields and f.name not in explicit_names
            end)

          explicitly_optimistic ++ auto_optimistic
        end

        def __lavash__(:optimistic_derives) do
          Spark.Dsl.Extension.get_entities(__MODULE__, [:derives])
          |> Enum.filter(&(Map.get(&1, :optimistic, false) == true))
        end

        def __lavash_calculations__ do
          Spark.Dsl.Extension.get_entities(__MODULE__, [:calculations])
          |> Enum.map(fn calc ->
            {calc.name, calc.rx.source, calc.rx.ast, calc.rx.deps,
             Map.get(calc, :optimistic, true), Map.get(calc, :async, false),
             Map.get(calc, :reads, [])}
          end)
        end

        def __lavash_optimistic_actions__ do
          @__lavash_optimistic_actions__ || []
        end

        unquote(colocated_ast)
      end
    )
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
      end
    else
      quote do
        @impl Phoenix.LiveView
        def mount(params, session, socket) do
          Lavash.LiveView.Runtime.mount(__MODULE__, params, session, socket)
        end
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
