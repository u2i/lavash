defmodule Lavash.ClientComponent.Compiler do
  @moduledoc """
  Compiler for ClientComponent DSL.

  Generates Elixir code only:
  - Client state function from bindings and props
  - Server-side calculation functions
  - Server handle_event functions from optimistic_actions
  - Render function from template

  JS generation and colocated hook writing is handled by the
  `Lavash.ClientComponent.Transformers.GenerateHook` transformer.
  """

  use Spark.Dsl.Extension

  alias Lavash.Component.CompilerHelpers

  @doc false
  defmacro __before_compile__(env) do
    # Read DSL entities (still needed for Elixir code generation)
    bindings = Spark.Dsl.Extension.get_entities(env.module, [:state_fields]) || []
    props = Spark.Dsl.Extension.get_entities(env.module, [:props]) || []

    # Read persisted data from GenerateHook transformer
    hook_data = Spark.Dsl.Extension.get_persisted(env.module, :lavash_cc_hook_data)
    js_code = Spark.Dsl.Extension.get_persisted(env.module, :lavash_cc_js_code)
    full_hook_name = Spark.Dsl.Extension.get_persisted(env.module, :lavash_cc_full_hook_name)
    calculations = Spark.Dsl.Extension.get_persisted(env.module, :lavash_cc_calculations) || []
    actions = Spark.Dsl.Extension.get_persisted(env.module, :lavash_cc_actions) || []
    template_source = Spark.Dsl.Extension.get_persisted(env.module, :lavash_cc_template_source)

    # Emit deprecation warning for legacy template name
    templates = Spark.Dsl.Extension.get_entities(env.module, [:template]) || []

    case templates do
      [%{deprecated_name: :client_template} | _] ->
        IO.warn("client_template is deprecated, use template instead", Macro.Env.stacktrace(env))

      _ ->
        :ok
    end

    # Generate hook name
    module_name = env.module |> Module.split() |> List.last()
    hook_name = ".#{module_name}"

    # Generate Elixir code
    client_state_fn = generate_client_state(bindings, props)
    calculation_fns = generate_calculations(calculations)
    handle_event_fns = generate_handle_events(actions)
    mount_update_fns = generate_mount_update()

    render_fn =
      if template_source do
        generate_render(template_source, full_hook_name)
      end

    escaped_hook_data = if hook_data, do: Macro.escape(hook_data), else: nil

    quote do
      def __hook_name__, do: unquote(hook_name)
      def __full_hook_name__, do: unquote(full_hook_name)
      def __generated_js__, do: unquote(js_code)

      if unquote(escaped_hook_data) do
        def __phoenix_macro_components__ do
          %{
            Phoenix.LiveView.ColocatedHook => [unquote(escaped_hook_data)]
          }
        end
      end

      unquote(mount_update_fns)
      unquote(client_state_fn)
      unquote(calculation_fns)
      unquote(handle_event_fns)
      unquote(render_fn)
    end
  end

  # ============================================
  # Elixir code generation
  # ============================================

  defp generate_mount_update do
    binding_resolution = CompilerHelpers.generate_binding_resolution_code()

    quote do
      def mount(socket) do
        socket =
          socket
          |> Phoenix.Component.assign(:__lavash_binding_map__, %{})
          |> Phoenix.Component.assign(:__lavash_version__, 0)

        {:ok, socket}
      end

      def update(assigns, socket) do
        socket = __resolve_bindings__(assigns, socket)
        {:ok, Phoenix.Component.assign(socket, Map.drop(assigns, [:bind, :__changed__]))}
      end

      unquote(binding_resolution)

      defp __notify_parent_binding__(socket, action, parent_field, value) do
        case socket.assigns[:__lavash_parent_cid__] do
          nil ->
            send(self(), {action, parent_field, value})

          parent_cid ->
            Phoenix.LiveView.send_update(parent_cid,
              __lavash_binding_update__: {action, parent_field, value}
            )
        end
      end
    end
  end

  defp generate_client_state(bindings, props) do
    binding_fields =
      Enum.map(bindings, fn %{name: name} ->
        {name, quote(do: Map.get(assigns, unquote(name), nil))}
      end)

    client_props =
      Enum.filter(props, fn prop ->
        Map.get(prop, :client, true) != false
      end)

    prop_fields =
      Enum.map(client_props, fn %{name: name, default: default} ->
        default_val = if default == nil, do: nil, else: Macro.escape(default)
        {name, quote(do: Map.get(assigns, unquote(name), unquote(default_val)))}
      end)

    all_fields = binding_fields ++ prop_fields

    quote do
      def client_state(assigns) do
        %{unquote_splicing(all_fields)}
      end
    end
  end

  defp generate_calculations([]) do
    quote do
      defp __compute_calculations__(state), do: state
      def __calculations__, do: []
    end
  end

  defp generate_calculations(calculations) do
    calc_clauses =
      Enum.map(calculations, fn {name, _source, transformed_expr, _deps} ->
        quote do
          defp __calc__(unquote(name), var!(state)) do
            _ = var!(state)
            unquote(transformed_expr)
          end
        end
      end)

    calc_names = Enum.map(calculations, fn {name, _, _, _} -> name end)

    compute_fn =
      quote do
        defp __compute_calculations__(state) do
          Enum.reduce(unquote(calc_names), state, fn name, acc ->
            value = __calc__(name, acc)
            Map.put(acc, name, value)
          end)
        end

        def __calculations__ do
          unquote(Macro.escape(calculations))
        end
      end

    {:__block__, [], calc_clauses ++ [compute_fn]}
  end

  defp generate_handle_events([]) do
    quote do
    end
  end

  defp generate_handle_events(actions) do
    Enum.map(actions, fn %{
                           name: action_name,
                           field: field,
                           key: key_field,
                           run_source: run_source,
                           validate_source: validate_source,
                           max: max_field
                         } ->
      event_name = "#{action_name}_#{field |> to_string() |> String.trim_trailing("s")}"

      run_fn_ast =
        case run_source do
          ":remove" -> quote(do: fn _item, _value -> :remove end)
          ":set" -> quote(do: fn _current, value -> value end)
          _ -> CompilerHelpers.parse_fn_source(run_source)
        end

      validate_fn_ast = CompilerHelpers.parse_fn_source(validate_source)
      condition_ast = build_condition_ast(validate_fn_ast, max_field)

      if key_field do
        quote do
          def handle_event(unquote(event_name), params, socket) do
            key_value = Map.get(params, "val")
            arg = Map.get(params, "arg", key_value)
            binding_map = socket.assigns[:__lavash_binding_map__] || %{}

            case Map.get(binding_map, unquote(field)) do
              nil ->
                current = socket.assigns[unquote(field)] || []

                if unquote(condition_ast) do
                  run_fn = unquote(run_fn_ast)

                  new_value =
                    Enum.flat_map(current, fn item ->
                      if Map.get(item, unquote(key_field)) == key_value do
                        case run_fn.(item, arg) do
                          :remove -> []
                          updated -> [updated]
                        end
                      else
                        [item]
                      end
                    end)

                  version = (socket.assigns[:__lavash_version__] || 0) + 1
                  socket = Phoenix.Component.assign(socket, :__lavash_version__, version)
                  {:noreply, Phoenix.Component.assign(socket, unquote(field), new_value)}
                else
                  {:noreply, socket}
                end

              parent_field ->
                __notify_parent_binding__(
                  socket,
                  unquote(:"lavash_component_#{action_name}"),
                  parent_field,
                  %{key: key_value, arg: arg}
                )

                {:noreply, socket}
            end
          end
        end
      else
        quote do
          def handle_event(unquote(event_name), params, socket) do
            value = Map.get(params, "val")
            binding_map = socket.assigns[:__lavash_binding_map__] || %{}

            case Map.get(binding_map, unquote(field)) do
              nil ->
                current = socket.assigns[unquote(field)] || []

                if unquote(condition_ast) do
                  run_fn = unquote(run_fn_ast)
                  new_value = run_fn.(current, value)
                  version = (socket.assigns[:__lavash_version__] || 0) + 1
                  socket = Phoenix.Component.assign(socket, :__lavash_version__, version)
                  {:noreply, Phoenix.Component.assign(socket, unquote(field), new_value)}
                else
                  {:noreply, socket}
                end

              parent_field ->
                __notify_parent_binding__(
                  socket,
                  unquote(:"lavash_component_#{action_name}"),
                  parent_field,
                  value
                )

                {:noreply, socket}
            end
          end
        end
      end
    end)
  end

  defp build_condition_ast(nil, nil), do: true

  defp build_condition_ast(validate_fn_ast, nil) when not is_nil(validate_fn_ast) do
    quote do
      validate_fn = unquote(validate_fn_ast)
      validate_fn.(current, value)
    end
  end

  defp build_condition_ast(nil, max_field) when not is_nil(max_field) do
    quote do
      max_val = socket.assigns[unquote(max_field)]
      max_val == nil or length(current) < max_val
    end
  end

  defp build_condition_ast(validate_fn_ast, max_field) do
    quote do
      validate_fn = unquote(validate_fn_ast)
      valid? = validate_fn.(current, value)
      max_val = socket.assigns[unquote(max_field)]
      under_max? = max_val == nil or length(current) < max_val
      valid? and under_max?
    end
  end

  defp generate_render(template_source, full_hook_name) do
    wrapper_template = """
    <div
      id={@id}
      phx-hook={@__hook_name__}
      phx-target={@myself}
      data-lavash-state={@__state_json__}
      data-lavash-version={@__version__}
      data-lavash-bindings={@__bindings_json__}
    >
      {@inner_content}
    </div>
    """

    quote do
      @__lavash_full_hook_name__ unquote(full_hook_name)
      @__lavash_template_source__ unquote(template_source)
      @__lavash_wrapper_template__ unquote(wrapper_template)

      @doc false
      defmacro __render_inner__(assigns_var) do
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

      @doc false
      defmacro __render_wrapper__(assigns_var) do
        template = Module.get_attribute(__MODULE__, :__lavash_wrapper_template__)

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

      def render(var!(assigns)) do
        state = client_state(var!(assigns))
        state = __compute_calculations__(state)
        state_json = Jason.encode!(state)

        version = Map.get(var!(assigns), :__lavash_version__, 0)
        client_bindings = Map.get(var!(assigns), :__lavash_client_bindings__)
        binding_map = client_bindings || Map.get(var!(assigns), :__lavash_binding_map__, %{})
        bindings_json = Jason.encode!(binding_map)

        var!(assigns) =
          var!(assigns)
          |> Phoenix.Component.assign(:client_state, state)
          |> Phoenix.Component.assign(:__state_json__, state_json)
          |> Phoenix.Component.assign(:__bindings_json__, bindings_json)
          |> Phoenix.Component.assign(:__hook_name__, @__lavash_full_hook_name__)
          |> Phoenix.Component.assign(:__version__, version)
          |> Phoenix.Component.assign(state)

        inner_content = __render_inner__(var!(assigns))
        var!(assigns) = Phoenix.Component.assign(var!(assigns), :inner_content, inner_content)

        __render_wrapper__(var!(assigns))
      end
    end
  end
end
