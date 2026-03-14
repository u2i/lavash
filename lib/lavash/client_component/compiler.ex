defmodule Lavash.ClientComponent.Compiler do
  @moduledoc """
  Compiler for ClientComponent DSL.

  Generates:
  - Client state function from bindings, props, and calculations
  - Server handle_event functions from optimistic_actions
  - JS hook code from template and optimistic_actions
  - Render function from template
  """

  use Spark.Dsl.Extension

  alias Lavash.Component.CompilerHelpers

  @doc false
  defmacro __before_compile__(env) do
    # Get DSL entities from Spark
    bindings = Spark.Dsl.Extension.get_entities(env.module, [:state_fields]) || []
    props = Spark.Dsl.Extension.get_entities(env.module, [:props]) || []
    templates = Spark.Dsl.Extension.get_entities(env.module, [:template]) || []

    # Check for render definitions from the new macro-based approach
    lavash_renders = Module.get_attribute(env.module, :__lavash_renders__) || []

    # Get calculations from Spark DSL entities and convert to tuple format
    # Each Calculate struct has :name and :rx (a Lavash.Rx struct with :source, :ast, :deps)
    spark_calculations = Spark.Dsl.Extension.get_entities(env.module, [:calculations]) || []

    calculations =
      spark_calculations
      |> Enum.map(fn calc ->
        {calc.name, calc.rx.source, calc.rx.ast, calc.rx.deps}
      end)
      |> topo_sort_calculations()

    # Actions are stored as tuples: {name, field, key, run_source, validate_source, max}
    action_tuples = Module.get_attribute(env.module, :__lavash_optimistic_actions__) || []
    actions = Enum.map(action_tuples, fn {name, field, key, run_source, validate_source, max} ->
      %{name: name, field: field, key: key, run_source: run_source, validate_source: validate_source, max: max}
    end)

    # Determine template source: prefer new macro-based render, fall back to DSL template
    {template_source, deprecated_name} =
      case lavash_renders do
        [] ->
          # Fall back to legacy template DSL
          case templates do
            [%{source: source, deprecated_name: deprecated} | _] -> {source, deprecated}
            [%{source: source} | _] -> {source, nil}
            _ -> {nil, nil}
          end

        renders ->
          # New macro-based renders - find :__render_fn__ and extract source
          renders_map = Map.new(renders)
          case Map.get(renders_map, :__render_fn__) do
            nil ->
              {nil, nil}

            escaped_fn ->
              # The escaped function contains the ~L sigil expansion
              # For ClientComponents, ~L returns %Lavash.Template.Compiled{source: "..."}
              # We need to extract the source from the function body AST
              extract_source_from_render_fn(escaped_fn)
          end
      end

    # Emit deprecation warning if client_template was used
    if deprecated_name == :client_template do
      IO.warn(
        "client_template is deprecated, use template instead",
        Macro.Env.stacktrace(env)
      )
    end

    # Build metadata for template transformation
    # Note: We build it manually here since module isn't compiled yet
    optimistic_actions_map =
      action_tuples
      |> Enum.map(fn {name, field, _key, _run, _validate, _max} -> {name, %{field: field}} end)
      |> Map.new()

    # Transform template to inject data-lavash-* attributes
    template_source =
      if template_source do
        metadata = %{
          context: :client_component,
          optimistic_fields: %{},  # ClientComponent uses bindings, not state fields
          optimistic_derives: %{},
          calculations: Enum.map(calculations, fn {name, _, _, _} -> {name, %{optimistic: true}} end) |> Map.new(),
          forms: %{},
          actions: %{},
          optimistic_actions: optimistic_actions_map
        }

        Lavash.Template.Transformer.transform(template_source, env.module,
          context: :client_component,
          metadata: metadata
        )
      else
        nil
      end

    # Generate hook name from module
    module_name = env.module |> Module.split() |> List.last()
    hook_name = ".#{module_name}"
    full_hook_name = "#{inspect(env.module)}.#{module_name}"

    # Generate code
    client_state_fn = generate_client_state(bindings, props)
    calculation_fns = generate_calculations(calculations)
    handle_event_fns = generate_handle_events(actions, bindings)

    # Generate JS and write to colocated hooks directory
    js_code = if template_source do
      generate_js_hook(template_source, calculations, actions, env)
    end

    hook_data = if js_code do
      CompilerHelpers.write_colocated_hook(env, full_hook_name, js_code)
    end

    render_fn = if template_source do
      generate_render(template_source, full_hook_name, env)
    end

    # Pre-escape hook_data before entering quote
    escaped_hook_data = if hook_data, do: Macro.escape(hook_data), else: nil

    # Generate mount and update callbacks
    mount_update_fns = generate_mount_update(bindings)

    quote do
      # Hook metadata
      def __hook_name__, do: unquote(hook_name)
      def __full_hook_name__, do: unquote(full_hook_name)
      def __generated_js__, do: unquote(js_code)

      # Phoenix colocated hooks integration
      if unquote(escaped_hook_data) do
        def __phoenix_macro_components__ do
          %{
            Phoenix.LiveView.ColocatedHook => [unquote(escaped_hook_data)]
          }
        end
      end

      # Mount and update callbacks for binding resolution
      unquote(mount_update_fns)

      # Client state function
      unquote(client_state_fn)

      # Calculation functions
      unquote(calculation_fns)

      # Handle event functions (from optimistic_actions)
      unquote(handle_event_fns)

      # Render function
      unquote(render_fn)
    end
  end

  # Generate mount and update callbacks for binding resolution
  # Uses shared binding resolution code from CompilerHelpers
  defp generate_mount_update(_bindings) do
    binding_resolution = CompilerHelpers.generate_binding_resolution_code()

    quote do
      # Initialize binding map and version tracking
      def mount(socket) do
        socket =
          socket
          |> Phoenix.Component.assign(:__lavash_binding_map__, %{})
          |> Phoenix.Component.assign(:__lavash_version__, 0)

        {:ok, socket}
      end

      # Resolve bindings from the `bind` prop
      def update(assigns, socket) do
        socket = __resolve_bindings__(assigns, socket)
        {:ok, Phoenix.Component.assign(socket, Map.drop(assigns, [:bind, :__changed__]))}
      end

      # Inject shared binding resolution code
      unquote(binding_resolution)

      # Notify parent about bound field updates
      # Routes to parent Lavash.Component via send_update, or to LiveView via send
      defp __notify_parent_binding__(socket, action, parent_field, value) do
        case socket.assigns[:__lavash_parent_cid__] do
          nil ->
            # No parent CID - send to LiveView process
            send(self(), {action, parent_field, value})

          parent_cid ->
            # Parent is a Lavash.Component - use send_update with CID
            Phoenix.LiveView.send_update(parent_cid, __lavash_binding_update__: {action, parent_field, value})
        end
      end
    end
  end

  # Generate client_state/1 function
  defp generate_client_state(bindings, props) do
    binding_fields = Enum.map(bindings, fn %{name: name} ->
      {name, quote do: Map.get(assigns, unquote(name), nil)}
    end)

    # Only include props with client: true (default) in client state
    # Props with client: false are server-only (e.g., Phoenix.LiveView.JS callbacks)
    client_props = Enum.filter(props, fn prop ->
      Map.get(prop, :client, true) != false
    end)

    prop_fields = Enum.map(client_props, fn %{name: name, default: default} ->
      default_val = Macro.escape(default || nil)
      {name, quote do: Map.get(assigns, unquote(name), unquote(default_val))}
    end)

    all_fields = binding_fields ++ prop_fields

    quote do
      def client_state(assigns) do
        %{unquote_splicing(all_fields)}
      end
    end
  end

  # Generate calculation functions
  defp generate_calculations([]) do
    quote do
      defp __compute_calculations__(state), do: state
      def __calculations__, do: []
    end
  end

  defp generate_calculations(calculations) do
    # Calculations are tuples: {name, source_string, transformed_expr, deps}
    calc_clauses = Enum.map(calculations, fn {name, _source, transformed_expr, _deps} ->
      quote do
        defp __calc__(unquote(name), var!(state)) do
          _ = var!(state)
          unquote(transformed_expr)
        end
      end
    end)

    calc_names = Enum.map(calculations, fn {name, _, _, _} -> name end)

    compute_fn = quote do
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

  # Generate handle_event functions from optimistic_actions
  defp generate_handle_events([], _bindings) do
    quote do
    end
  end

  defp generate_handle_events(actions, _bindings) do
    Enum.map(actions, fn %{name: action_name, field: field, key: key_field, run_source: run_source, validate_source: validate_source, max: max_field} ->
      event_name = "#{action_name}_#{field |> to_string() |> String.trim_trailing("s")}"

      # Handle shorthand run values
      run_fn_ast = case run_source do
        ":remove" -> quote do: fn _item, _value -> :remove end
        ":set" -> quote do: fn _current, value -> value end
        _ -> CompilerHelpers.parse_fn_source(run_source)
      end

      validate_fn_ast = CompilerHelpers.parse_fn_source(validate_source)

      # Build the condition AST based on which checks are needed
      condition_ast = build_condition_ast(validate_fn_ast, max_field)

      # Generate different code paths for key-based vs non-key-based actions
      if key_field do
        # Key-based action: find item by key, apply transformation
        quote do
          def handle_event(unquote(event_name), params, socket) do
            # For key-based actions, "val" is the key value to find the item
            # "arg" is the argument passed to the run function (optional)
            key_value = Map.get(params, "val")
            arg = Map.get(params, "arg", key_value)
            binding_map = socket.assigns[:__lavash_binding_map__] || %{}

            case Map.get(binding_map, unquote(field)) do
              nil ->
                # Not bound - update own assigns
                current = socket.assigns[unquote(field)] || []

                if unquote(condition_ast) do
                  run_fn = unquote(run_fn_ast)

                  # Find item by key and apply transformation
                  new_value = Enum.flat_map(current, fn item ->
                    if Map.get(item, unquote(key_field)) == key_value do
                      case run_fn.(item, arg) do
                        :remove -> []
                        updated -> [updated]
                      end
                    else
                      [item]
                    end
                  end)

                  # Bump version to signal state change to client
                  version = (socket.assigns[:__lavash_version__] || 0) + 1
                  socket = Phoenix.Component.assign(socket, :__lavash_version__, version)
                  {:noreply, Phoenix.Component.assign(socket, unquote(field), new_value)}
                else
                  {:noreply, socket}
                end

              parent_field ->
                # Bound to parent - route to parent component or LiveView
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
        # Non-key-based action: original behavior
        quote do
          def handle_event(unquote(event_name), params, socket) do
            # Extract value from params (may be nil for toggle actions)
            value = Map.get(params, "val")
            binding_map = socket.assigns[:__lavash_binding_map__] || %{}

            case Map.get(binding_map, unquote(field)) do
              nil ->
                # Not bound - update own assigns
                current = socket.assigns[unquote(field)] || []

                if unquote(condition_ast) do
                  # Call the run function directly
                  run_fn = unquote(run_fn_ast)
                  new_value = run_fn.(current, value)
                  # Bump version to signal state change to client
                  version = (socket.assigns[:__lavash_version__] || 0) + 1
                  socket = Phoenix.Component.assign(socket, :__lavash_version__, version)
                  {:noreply, Phoenix.Component.assign(socket, unquote(field), new_value)}
                else
                  {:noreply, socket}
                end

              parent_field ->
                # Bound to parent - route to parent component or LiveView
                __notify_parent_binding__(socket, unquote(:"lavash_component_#{action_name}"), parent_field, value)
                {:noreply, socket}
            end
          end
        end
      end
    end)
  end

  # Build the validation condition based on what checks are needed
  defp build_condition_ast(nil, nil) do
    # No validation, no max - always proceed
    true
  end

  defp build_condition_ast(validate_fn_ast, nil) when not is_nil(validate_fn_ast) do
    # Only validation check - call the validate fn
    quote do
      validate_fn = unquote(validate_fn_ast)
      validate_fn.(current, value)
    end
  end

  defp build_condition_ast(nil, max_field) when not is_nil(max_field) do
    # Only max check
    quote do
      max_val = socket.assigns[unquote(max_field)]
      max_val == nil or length(current) < max_val
    end
  end

  defp build_condition_ast(validate_fn_ast, max_field) do
    # Both validation and max check
    quote do
      validate_fn = unquote(validate_fn_ast)
      valid? = validate_fn.(current, value)
      max_val = socket.assigns[unquote(max_field)]
      under_max? = max_val == nil or length(current) < max_val
      valid? and under_max?
    end
  end

  # Generate JS hook code
  defp generate_js_hook(template_source, calculations, actions, _env) do
    # Parse template and generate render function
    tree = template_source
    |> Lavash.Template.tokenize()
    |> Lavash.Template.parse()

    render_parts = tree_to_js_parts(tree, %{})
    render_body = "`" <> Enum.join(render_parts, "") <> "`"

    # Generate calculation functions as a fns object for ReactiveStore
    calc_fns_js = generate_calculation_fns_js(calculations)

    # Generate dependency graph for ReactiveStore
    graph_js = generate_calculation_graph_js(calculations)

    # Generate action JS
    action_js = generate_action_js(actions)

    # Combine into hook
    ~s"""
    import { createClientComponentHook, humanize } from "lavash/client_component.js";

    export default createClientComponentHook({
      fns: #{calc_fns_js},
      graph: #{graph_js},
      render(state) {
        return #{render_body};
      },
    #{action_js}
    });
    """
  end

  # Generate calculation functions as a JS object literal for ReactiveStore
  # Input: list of {name, source_string, transformed_expr, deps} tuples
  # Output: JS string like `{ is_empty: (s) => ..., item_count: (s) => ... }`
  defp generate_calculation_fns_js([]), do: "{}"

  defp generate_calculation_fns_js(calculations) do
    entries =
      calculations
      |> Enum.map(fn {name, source, _transformed_expr, _deps} ->
        js_expr = Lavash.Rx.Transpiler.to_js(source)
        "    #{name}: (state) => (#{js_expr})"
      end)
      |> Enum.join(",\n")

    "{\n#{entries}\n  }"
  end

  # Generate a dependency graph JS object literal for ReactiveStore
  # Uses Lavash.Graph to build dependents from the deps map
  # Output: JS string like `{ topo_order: [...], deps: {...}, dependents: {...} }`
  defp generate_calculation_graph_js([]) do
    ~s|{ topo_order: [], deps: {}, dependents: {} }|
  end

  defp generate_calculation_graph_js(calculations) do
    # Build full deps map including state field dependencies (e.g., items, tags)
    # This is needed so recomputeGraph(["items"]) finds affected calculations
    full_deps_map =
      Map.new(calculations, fn {name, _, _, deps} ->
        {name, deps}
      end)

    # Topo order (already sorted, just extract names)
    topo_order = Enum.map(calculations, fn {name, _, _, _} -> name end)

    # Build dependents from full deps (includes state fields as keys)
    dependents = Lavash.Graph.build_dependents(full_deps_map)

    topo_json = Jason.encode!(Enum.map(topo_order, &to_string/1))

    deps_json =
      full_deps_map
      |> Enum.map(fn {name, deps} ->
        ~s|#{name}: #{Jason.encode!(Enum.map(deps, &to_string/1))}|
      end)
      |> Enum.join(", ")

    dependents_json =
      dependents
      |> Enum.map(fn {name, deps} ->
        ~s|#{name}: #{Jason.encode!(Enum.map(deps, &to_string/1))}|
      end)
      |> Enum.join(", ")

    ~s|{ topo_order: #{topo_json}, deps: { #{deps_json} }, dependents: { #{dependents_json} } }|
  end

  # Generate JS for optimistic actions
  defp generate_action_js(actions) do
    action_cases = Enum.map(actions, fn %{name: action_name, field: field, key: key_field, run_source: run_source} ->
      if key_field do
        # Key-based action: find item by key, apply transformation
        run_js = generate_keyed_action_js(run_source, key_field)
        ~s|    if (action === "#{action_name}" && field === "#{field}") {\n#{run_js}\n    }|
      else
        # Non-key-based action: handle shorthands or compile function
        run_js = case run_source do
          ":set" ->
            # :set shorthand - parse value and assign directly
            ~s|state.#{field} = value === "true" ? true : value === "false" ? false : value;|
          _ ->
            CompilerHelpers.fn_source_to_js_assignment(run_source, field)
        end
        ~s|    if (action === "#{action_name}" && field === "#{field}") {\n      #{run_js}\n    }|
      end
    end)
    |> Enum.join("\n")

    validate_cases = Enum.map(actions, fn %{name: action_name, field: field, validate_source: validate_source, max: max_field} ->
      conditions = []

      conditions = if validate_source do
        validate_js = CompilerHelpers.fn_source_to_js_bool(validate_source)
        [~s|!(#{validate_js})| | conditions]
      else
        conditions
      end

      conditions = if max_field do
        [~s|(state.#{max_field} && current.length >= state.#{max_field})| | conditions]
      else
        conditions
      end

      if conditions == [] do
        ""
      else
        condition = Enum.join(conditions, " || ")
        ~s|    if (action === "#{action_name}" && field === "#{field}") {\n      if (#{condition}) return false;\n    }|
      end
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")

    ~s"""
      validateAction(action, field, value, arg, state) {
        const current = state[field];
    #{validate_cases}
        return true;
      },

      applyOptimisticAction(action, field, value, arg, state) {
        const current = state[field];
    #{action_cases}
      },
    """
  end

  # Generate JS for key-based array mutations
  defp generate_keyed_action_js(run_source, key_field) do
    key_str = to_string(key_field)

    if run_source == ":remove" do
      # Shorthand for removal - filter out the item
      ~s|      if (!current) return;
      state[field] = current.filter(item => item.#{key_str} !== value);|
    else
      # Transform function - map over items and update matching one
      # Parse the Elixir function and convert to JS
      item_transform_js = CompilerHelpers.fn_source_to_js_item_transform(run_source)
      ~s|      if (!current) return;
      state[field] = current.map(item => {
        if (item.#{key_str} === value) {
          const result = #{item_transform_js};
          return result === 'remove' ? null : result;
        }
        return item;
      }).filter(item => item !== null);|
    end
  end

  # Generate render function
  defp generate_render(template_source, full_hook_name, _env) do
    # The wrapper template - compiled at target module's compile time via macro
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
      # Store template source for __render_inner__ macro
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
        # Use client bindings (resolved/flattened) for JS if available, fall back to regular binding map
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

  # Delegate to Lavash.Template for tree_to_js_parts
  defp tree_to_js_parts(nodes, ctx) when is_list(nodes) do
    Enum.flat_map(nodes, &node_to_js_parts(&1, ctx))
  end

  defp node_to_js_parts({:text, content}, _ctx) do
    escaped = content
    |> String.replace("\\", "\\\\")
    |> String.replace("`", "\\`")
    |> String.replace("${", "\\${")
    [escaped]
  end

  defp node_to_js_parts({:expr, code, _meta}, _ctx) do
    js_expr = Lavash.Rx.Transpiler.to_js(code)
    ["${#{js_expr}}"]
  end

  defp node_to_js_parts({:element, tag, attrs, children, meta}, ctx) do
    case find_special_attr(attrs, :for) do
      {:for, for_expr} ->
        {var, collection_js} = parse_for_to_js(for_expr)
        attrs_without_for = reject_special_attr(attrs, :for)
        new_ctx = Map.put(ctx, :loop_var, var)
        inner = render_element_wrapped(tag, attrs_without_for, children, meta, new_ctx)
        ["${#{collection_js}.map(#{var} => #{inner}).join('')}"]

      nil ->
        case find_special_attr(attrs, :if) do
          {:if, if_expr} ->
            condition_js = Lavash.Rx.Transpiler.to_js(if_expr)
            attrs_without_if = reject_special_attr(attrs, :if)
            inner = render_element_wrapped(tag, attrs_without_if, children, meta, ctx)
            ["${#{condition_js} ? #{inner} : ''}"]

          nil ->
            render_element_parts(tag, attrs, children, meta, ctx)
        end
    end
  end

  defp node_to_js_parts({:special_attr, _, _, _, _}, _ctx), do: []

  # HTML void elements that cannot have children and must not have closing tags
  @void_elements ~w(area base br col embed hr img input link meta source track wbr)

  defp render_element_parts(tag, attrs, children, _meta, ctx) do
    attrs_js = render_attrs_to_js(attrs, ctx)

    if children == [] do
      if tag in @void_elements do
        ["<#{tag}#{attrs_js}>"]
      else
        ["<#{tag}#{attrs_js}></#{tag}>"]
      end
    else
      children_parts = tree_to_js_parts(children, ctx)
      ["<#{tag}#{attrs_js}>"] ++ children_parts ++ ["</#{tag}>"]
    end
  end

  defp render_element_wrapped(tag, attrs, children, _meta, ctx) do
    attrs_js = render_attrs_to_js(attrs, ctx)

    if children == [] do
      if tag in @void_elements do
        "`<#{tag}#{attrs_js}>`"
      else
        "`<#{tag}#{attrs_js}></#{tag}>`"
      end
    else
      children_parts = tree_to_js_parts(children, ctx)
      children_js = Enum.join(children_parts, "")
      "`<#{tag}#{attrs_js}>#{children_js}</#{tag}>`"
    end
  end

  defp render_attrs_to_js(attrs, ctx) do
    attrs
    |> Enum.reject(fn {name, _} -> String.starts_with?(name, ":") end)
    |> Enum.map(fn {name, value} -> render_attr_to_js(name, value, ctx) end)
    |> Enum.join("")
  end

  defp render_attr_to_js(name, {:string, value}, _ctx) do
    escaped = value
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    " #{name}=\"#{escaped}\""
  end

  defp render_attr_to_js(name, {:expr, code, _}, _ctx) do
    js_expr = Lavash.Rx.Transpiler.to_js(code)
    " #{name}=\"${#{js_expr}}\""
  end

  defp render_attr_to_js(name, {:boolean, true}, _ctx), do: " #{name}"
  defp render_attr_to_js(_name, {:boolean, false}, _ctx), do: ""
  defp render_attr_to_js(_name, _value, _ctx), do: ""

  defp find_special_attr(attrs, type) do
    key = ":#{type}"
    case Enum.find(attrs, fn {name, _} -> name == key end) do
      {^key, {:expr, code, _}} -> {type, code}
      _ -> nil
    end
  end

  defp reject_special_attr(attrs, type) do
    key = ":#{type}"
    Enum.reject(attrs, fn {name, _} -> name == key end)
  end

  defp parse_for_to_js(code) do
    case Code.string_to_quoted(code) do
      {:ok, {:<-, _, [{var, _, _}, collection]}} when is_atom(var) ->
        {to_string(var), Lavash.Rx.Transpiler.to_js(Macro.to_string(collection))}
      _ ->
        {"item", "[]"}
    end
  end

  # Extract template source from render function AST
  # The function looks like: fn assigns -> %Lavash.Template.Compiled{source: "...", ...} end
  defp extract_source_from_render_fn(escaped_fn) do
    case escaped_fn do
      # Match the function structure: fn assigns -> body end
      {:fn, _, [{:->, _, [[{:assigns, _, _}], body]}]} ->
        extract_compiled_source(body)

      # Also handle the case where assigns might have a different context
      {:fn, _, [{:->, _, [[_assigns_var], body]}]} ->
        extract_compiled_source(body)

      _ ->
        {nil, nil}
    end
  end

  # Extract source from the Compiled struct construction in the function body
  defp extract_compiled_source(body) do
    case body do
      # Match the ~L sigil call directly (before macro expansion)
      # The sigil AST is: {:sigil_L, meta, [{:<<>>, _, [template_string]}, modifiers]}
      {:sigil_L, _, [{:<<>>, _, [template_string]}, _modifiers]} when is_binary(template_string) ->
        {template_string, nil}

      # Match: %Lavash.Template.Compiled{source: "...", ...}
      {:%, _, [{:__aliases__, _, [:Lavash, :Template, :Compiled]}, {:%{}, _, fields}]} ->
        case Keyword.get(fields, :source) do
          source when is_binary(source) -> {source, nil}
          _ -> {nil, nil}
        end

      # Match: {:__block__, _, [contents]} - unwrap block and recurse
      {:__block__, _, [inner]} ->
        extract_compiled_source(inner)

      # Match the quote block that sigil_L returns for client components
      # This is the AST of: quote do %Lavash.Template.Compiled{...} end
      {:quote, _, [[do: struct_ast]]} ->
        extract_compiled_source(struct_ast)

      # If it's not a Compiled struct, render fn syntax not compatible with ClientComponent yet
      _ ->
        {nil, nil}
    end
  end

  # Sort calculations in dependency order using Lavash.Graph.topo_sort.
  # Each calculation is {name, source, ast, deps} where deps is a list of atoms.
  # Calculations that depend on other calculations must run after them.
  defp topo_sort_calculations(calculations) do
    calc_names = MapSet.new(calculations, fn {name, _, _, _} -> name end)

    # Build deps map containing only inter-calculation dependencies
    deps_map =
      Map.new(calculations, fn {name, _, _, deps} ->
        calc_deps = deps |> Enum.filter(&MapSet.member?(calc_names, &1))
        {name, calc_deps}
      end)

    sorted = Lavash.Graph.topo_sort(deps_map)
    calc_by_name = Map.new(calculations, fn {name, _, _, _} = calc -> {name, calc} end)
    Enum.map(sorted, &Map.fetch!(calc_by_name, &1))
  end
end
