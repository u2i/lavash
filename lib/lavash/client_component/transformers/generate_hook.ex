defmodule Lavash.ClientComponent.Transformers.GenerateHook do
  @moduledoc """
  Spark transformer that generates the ClientComponent JS hook and writes it
  as a colocated file.

  Reads DSL entities (bindings, props, calculations, template) and module
  attributes (optimistic_actions, renders), generates the complete JS hook
  via `createClientComponentHook(...)`, writes it to the colocated directory,
  and persists the result so the compiler can register it with Phoenix.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer
  alias Lavash.Component.CompilerHelpers

  # Run after ExpandAnimatedStates so animated state entities are available
  def after?(Lavash.Optimistic.Transformers.ExpandAnimatedStates), do: true
  def after?(_), do: false

  def before?(_), do: false

  def transform(dsl_state) do
    module = Transformer.get_persisted(dsl_state, :module)
    env = Transformer.get_persisted(dsl_state, :env)

    if is_nil(module) or is_nil(env) do
      {:ok, dsl_state}
    else
      generate_and_persist(dsl_state, module, env)
    end
  end

  defp generate_and_persist(dsl_state, _module, env) do
    # Read DSL entities
    templates = Transformer.get_entities(dsl_state, [:template]) || []

    # Read module attributes set by macros
    lavash_renders = Module.get_attribute(env.module, :__lavash_renders__) || []

    # Get calculations from Spark DSL
    spark_calculations = Transformer.get_entities(dsl_state, [:calculations]) || []

    calculations =
      spark_calculations
      |> Enum.map(fn calc ->
        {calc.name, calc.rx.source, calc.rx.ast, calc.rx.deps}
      end)
      |> topo_sort_calculations()

    # Get actions from module attributes
    action_tuples = Module.get_attribute(env.module, :__lavash_optimistic_actions__) || []

    actions =
      Enum.map(action_tuples, fn {name, field, key, run_source, validate_source, max} ->
        %{name: name, field: field, key: key, run_source: run_source, validate_source: validate_source, max: max}
      end)

    # Determine template source
    template_source = resolve_template_source(lavash_renders, templates)

    # Transform template to inject data-lavash-* attributes
    template_source =
      if template_source do
        optimistic_actions_map =
          action_tuples
          |> Enum.map(fn {name, field, _key, _run, _validate, _max} -> {name, %{field: field}} end)
          |> Map.new()

        metadata = %{
          context: :client_component,
          optimistic_fields: %{},
          optimistic_derives: %{},
          calculations:
            calculations
            |> Enum.map(fn {name, _, _, _} -> {name, %{optimistic: true}} end)
            |> Map.new(),
          forms: %{},
          actions: %{},
          optimistic_actions: optimistic_actions_map
        }

        Lavash.Template.Transformer.transform(template_source, env.module,
          context: :client_component,
          metadata: metadata
        )
      end

    # Generate JS hook
    js_code =
      if template_source do
        generate_js_hook(template_source, calculations, actions)
      end

    # Write colocated hook file
    module_name = env.module |> Module.split() |> List.last()
    full_hook_name = "#{inspect(env.module)}.#{module_name}"

    hook_data =
      if js_code do
        CompilerHelpers.write_colocated_hook(env, full_hook_name, js_code)
      end

    # Persist everything the compiler needs
    dsl_state =
      dsl_state
      |> Transformer.persist(:lavash_cc_hook_data, hook_data)
      |> Transformer.persist(:lavash_cc_js_code, js_code)
      |> Transformer.persist(:lavash_cc_full_hook_name, full_hook_name)
      |> Transformer.persist(:lavash_cc_calculations, calculations)
      |> Transformer.persist(:lavash_cc_actions, actions)
      |> Transformer.persist(:lavash_cc_template_source, template_source)

    {:ok, dsl_state}
  end

  # ============================================
  # Template resolution
  # ============================================

  defp resolve_template_source(lavash_renders, templates) do
    case lavash_renders do
      [] ->
        case templates do
          [%{source: source} | _] -> source
          _ -> nil
        end

      renders ->
        renders_map = Map.new(renders)

        case Map.get(renders_map, :__render_fn__) do
          nil -> nil
          escaped_fn -> extract_source_from_render_fn(escaped_fn)
        end
    end
  end

  defp extract_source_from_render_fn(escaped_fn) do
    case escaped_fn do
      {:fn, _, [{:->, _, [[_assigns_var], body]}]} ->
        extract_compiled_source(body)

      _ ->
        nil
    end
  end

  defp extract_compiled_source({:sigil_L, _, [{:<<>>, _, [template_string]}, _modifiers]})
       when is_binary(template_string),
       do: template_string

  defp extract_compiled_source({:%, _, [{:__aliases__, _, [:Lavash, :Template, :Compiled]}, {:%{}, _, fields}]}) do
    case Keyword.get(fields, :source) do
      source when is_binary(source) -> source
      _ -> nil
    end
  end

  defp extract_compiled_source({:__block__, _, [inner]}), do: extract_compiled_source(inner)
  defp extract_compiled_source({:quote, _, [[do: struct_ast]]}), do: extract_compiled_source(struct_ast)
  defp extract_compiled_source(_), do: nil

  # ============================================
  # JS generation
  # ============================================

  def generate_js_hook(template_source, calculations, actions) do
    tree =
      template_source
      |> Lavash.Template.tokenize()
      |> Lavash.Template.parse()

    render_parts = tree_to_js_parts(tree, %{})
    render_body = "`" <> Enum.join(render_parts, "") <> "`"

    calc_fns_js = generate_calculation_fns_js(calculations)
    graph_js = generate_calculation_graph_js(calculations)
    action_js = generate_action_js(actions)

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

  # ============================================
  # Calculation JS generation
  # ============================================

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

  defp generate_calculation_graph_js([]) do
    ~s|{ topo_order: [], deps: {}, dependents: {} }|
  end

  defp generate_calculation_graph_js(calculations) do
    full_deps_map =
      Map.new(calculations, fn {name, _, _, deps} ->
        {name, deps}
      end)

    topo_order = Enum.map(calculations, fn {name, _, _, _} -> name end)
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

  # ============================================
  # Action JS generation
  # ============================================

  defp generate_action_js(actions) do
    action_cases =
      actions
      |> Enum.map(fn %{name: action_name, field: field, key: key_field, run_source: run_source} ->
        if key_field do
          run_js = generate_keyed_action_js(run_source, key_field)
          ~s|    if (action === "#{action_name}" && field === "#{field}") {\n#{run_js}\n    }|
        else
          run_js =
            case run_source do
              ":set" ->
                ~s|state.#{field} = value === "true" ? true : value === "false" ? false : value;|

              _ ->
                CompilerHelpers.fn_source_to_js_assignment(run_source, field)
            end

          ~s|    if (action === "#{action_name}" && field === "#{field}") {\n      #{run_js}\n    }|
        end
      end)
      |> Enum.join("\n")

    validate_cases =
      actions
      |> Enum.map(fn %{name: action_name, field: field, validate_source: validate_source, max: max_field} ->
        conditions = []

        conditions =
          if validate_source do
            validate_js = CompilerHelpers.fn_source_to_js_bool(validate_source)
            [~s|!(#{validate_js})| | conditions]
          else
            conditions
          end

        conditions =
          if max_field do
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

  defp generate_keyed_action_js(run_source, key_field) do
    key_str = to_string(key_field)

    if run_source == ":remove" do
      ~s|      if (!current) return;
      state[field] = current.filter(item => item.#{key_str} !== value);|
    else
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

  # ============================================
  # Template to JS
  # ============================================

  defp tree_to_js_parts(nodes, ctx) when is_list(nodes) do
    Enum.flat_map(nodes, &node_to_js_parts(&1, ctx))
  end

  defp node_to_js_parts({:text, content}, _ctx) do
    escaped =
      content
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
    escaped =
      value
      |> String.replace("&", "&amp;")
      |> String.replace("\"", "&quot;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")

    " #{name}=\"#{escaped}\""
  end

  @boolean_attrs ~w(disabled checked readonly required hidden selected autofocus autoplay controls loop muted novalidate open)

  defp render_attr_to_js(name, {:expr, code, _}, _ctx) do
    js_expr = Lavash.Rx.Transpiler.to_js(code)

    if name in @boolean_attrs do
      # Boolean HTML attributes: presence = true, absence = false
      " ${#{js_expr} ? '#{name}' : ''}"
    else
      " #{name}=\"${#{js_expr}}\""
    end
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

  # ============================================
  # Topo sort
  # ============================================

  defp topo_sort_calculations(calculations) do
    calc_names = MapSet.new(calculations, fn {name, _, _, _} -> name end)

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
