defmodule Lavash.Component.Transformers.GenerateClientHook do
  @moduledoc """
  Spark transformer that generates a client-side JS hook for a Lavash Component.

  When a component has actions with transpilable `rx()` expressions, this
  transformer generates a colocated JS hook (via `createClientComponentHook`)
  that enables optimistic client-side rendering.

  The hook provides:
  - A JS render function transpiled from the `~L` template
  - Action functions transpiled from `set :field, rx(...)` expressions
  - Derive functions from `calculate :name, rx(...)` declarations
  - morphdom-based DOM patching for instant UI updates

  Only generates a hook if the component has transpilable actions.
  Components without optimistic actions remain server-rendered only.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer
  alias Lavash.Optimistic.ActionJs

  # Run after ExpandAnimatedStates and ExpandFields
  def after?(Lavash.Optimistic.Transformers.ExpandAnimatedStates), do: true
  def after?(Lavash.Transformers.ExpandFields), do: true
  def after?(_), do: false

  # Run before ExtractColocatedJs
  def before?(Lavash.Optimistic.Transformers.ExtractColocatedJs), do: true
  def before?(_), do: false

  def transform(dsl_state) do
    module = Transformer.get_persisted(dsl_state, :module)
    env = Transformer.get_persisted(dsl_state, :env)

    if is_nil(module) or is_nil(env) do
      {:ok, dsl_state}
    else
      has_overlay = Transformer.get_persisted(dsl_state, :lavash_overlay_render_generator) != nil

      # Build optimistic names early — used for attr derives and subtree detection
      all_optimistic_names = build_optimistic_names(dsl_state)

      lavash_renders = Module.get_attribute(env.module, :__lavash_renders__) || []
      template_source = resolve_template_source(lavash_renders)

      # Always try to extract attr derives from the template source
      dsl_state = maybe_extract_attr_derives(dsl_state, template_source, all_optimistic_names)

      actions = Transformer.get_entities(dsl_state, [:actions]) || []

      # Consider actions where ALL sets are transpilable to JS
      optimistic_actions =
        actions
        |> Enum.filter(fn action ->
          sets = action.sets || []
          updates = action.updates || []
          map_bys = action.map_bys || []
          has_transpilable = (sets ++ updates ++ map_bys) != []

          has_transpilable &&
            Enum.all?(sets, fn set ->
              case ActionJs.analyze_value(set.value) do
                {:rx, _} -> true
                {:literal, _} -> true
                :from_params_value -> true
                _ -> false
              end
            end) &&
            Enum.all?(map_bys, fn _mb -> true end)
        end)

      if optimistic_actions == [] or has_overlay do
        {:ok, dsl_state}
      else
        # Include action target fields as optimistic names for subtree detection
        action_field_names =
          optimistic_actions
          |> Enum.flat_map(fn action ->
            sets = action.sets || []
            updates = action.updates || []
            map_bys = action.map_bys || []
            Enum.map(sets, & &1.field) ++ Enum.map(updates, & &1.field) ++ Enum.map(map_bys, & &1.field)
          end)

        all_names = MapSet.union(all_optimistic_names, MapSet.new(action_field_names))

        # Extract subtree derives for :if/:for over optimistic state
        subtree_derives =
          if template_source do
            extract_subtree_derives(template_source, all_names)
          else
            []
          end

        # Persist subtree derives if any were found.
        # No full JS hook needed — substitution (data-lavash-*) handles
        # simple state updates, subtree derives handle :if/:for.
        dsl_state =
          if subtree_derives != [] do
            Transformer.persist(dsl_state, :lavash_subtree_derives, subtree_derives)
          else
            dsl_state
          end

        {:ok, dsl_state}
      end
    end
  end

  defp build_optimistic_names(dsl_state) do
    calculations =
      (Transformer.get_entities(dsl_state, [:calculations]) || [])
      |> Enum.filter(&Map.get(&1, :optimistic, true))

    calc_names = Enum.map(calculations, & &1.name)

    forms = Transformer.get_entities(dsl_state, [:forms]) || []
    form_derive_names = Enum.map(forms, fn f -> :"#{f.name}_valid" end)

    MapSet.new(calc_names ++ form_derive_names)
  end

  defp maybe_extract_attr_derives(dsl_state, template_source, all_optimistic_names) do
    if template_source do
      attr_derives = extract_attr_derives(template_source, all_optimistic_names)

      if attr_derives != [] do
        Transformer.persist(dsl_state, :lavash_attr_derives, attr_derives)
      else
        dsl_state
      end
    else
      dsl_state
    end
  end

  # ============================================
  # Subtree derive extraction
  # ============================================

  # Walk the parsed template tree. When a parent element has a child with
  # :if/:for over optimistic state, transpile ALL of that parent's children
  # to a JS render derive. The parent gets data-lavash-html at token time;
  # JS replaces its innerHTML on optimistic updates.
  defp extract_subtree_derives(template_source, optimistic_names) do
    tree =
      template_source
      |> Lavash.Template.tokenize()
      |> Lavash.Template.parse()

    {derives, _index} = find_parent_subtrees(tree, optimistic_names, [], 0)
    Enum.reverse(derives)
  end

  defp find_parent_subtrees(nodes, optimistic_names, acc, index) when is_list(nodes) do
    Enum.reduce(nodes, {acc, index}, fn node, {a, i} ->
      find_parent_subtrees(node, optimistic_names, a, i)
    end)
  end

  defp find_parent_subtrees({:element, tag, _attrs, children, _meta}, optimistic_names, acc, index) do
    # Check if any direct child has :if/:for over optimistic state
    if has_optimistic_child?(children, optimistic_names) do
      # Transpile ALL children to JS — this parent becomes the derive target
      children_js =
        children
        |> Enum.map(&Lavash.Component.JsGenerator.subtree_to_js/1)
        |> Enum.join("")

      derive_name = "__subtree_#{index}"
      all_deps = collect_all_optimistic_deps(children, optimistic_names)

      derive = %{
        name: derive_name,
        js_expr: "`#{children_js}`",
        deps: all_deps |> Enum.map(&to_string/1) |> Enum.uniq(),
        parent_tag: tag
      }

      {[derive | acc], index + 1}
    else
      # No optimistic :if/:for in direct children — recurse deeper
      find_parent_subtrees(children, optimistic_names, acc, index)
    end
  end

  defp find_parent_subtrees(_node, _optimistic_names, acc, index), do: {acc, index}

  defp has_optimistic_child?(children, optimistic_names) do
    Enum.any?(children, fn
      {:element, _tag, attrs, _children, _meta} ->
        match?({:ok, _}, optimistic_conditional(attrs, optimistic_names))
      _ ->
        false
    end)
  end

  # Check if element has :if or :for referencing optimistic state
  defp optimistic_conditional(attrs, optimistic_names) do
    conditional_attr =
      Enum.find(attrs, fn
        {":if", {:expr, _code, _meta}} -> true
        {":for", {:expr, _code, _meta}} -> true
        _ -> false
      end)

    case conditional_attr do
      {_name, {:expr, code, _meta}} ->
        deps =
          Regex.scan(~r/@(\w+)/, code)
          |> Enum.map(fn [_, field] -> String.to_atom(field) end)
          |> Enum.filter(&MapSet.member?(optimistic_names, &1))

        if deps != [], do: {:ok, deps}, else: :skip

      _ ->
        :skip
    end
  end

  # Collect all @field references from a subtree that are in optimistic_names
  defp collect_all_optimistic_deps(nodes, optimistic_names) when is_list(nodes) do
    Enum.flat_map(nodes, &collect_all_optimistic_deps(&1, optimistic_names))
  end

  defp collect_all_optimistic_deps({:element, _tag, attrs, children, _meta}, optimistic_names) do
    attr_deps =
      Enum.flat_map(attrs, fn
        {_name, {:expr, code, _meta}} ->
          Regex.scan(~r/@(\w+)/, code)
          |> Enum.map(fn [_, field] -> String.to_atom(field) end)
          |> Enum.filter(&MapSet.member?(optimistic_names, &1))
        _ -> []
      end)

    attr_deps ++ collect_all_optimistic_deps(children, optimistic_names)
  end

  defp collect_all_optimistic_deps({:expr, code, _meta}, optimistic_names) do
    Regex.scan(~r/@(\w+)/, code)
    |> Enum.map(fn [_, field] -> String.to_atom(field) end)
    |> Enum.filter(&MapSet.member?(optimistic_names, &1))
  end

  defp collect_all_optimistic_deps(_node, _optimistic_names), do: []

  # Extract reactive attribute derives from template source
  defp extract_attr_derives(template_source, optimistic_names) do
    # Find attributes like disabled={expr} and class={expr} that reference optimistic fields
    # Pattern: attr_name={elixir_expression} where expression contains @optimistic_field
    Regex.scan(~r/(disabled|class|hidden)=\{([^}]+)\}/, template_source)
    |> Enum.with_index()
    |> Enum.flat_map(fn {[_full, attr_name, expr], index} ->
      # Extract @field references
      deps =
        Regex.scan(~r/@(\w+)/, expr)
        |> Enum.map(fn [_, field] -> String.to_atom(field) end)
        |> Enum.filter(&MapSet.member?(optimistic_names, &1))
        |> Enum.uniq()

      if deps != [] do
        # Transpile the expression to JS
        case try_transpile(expr) do
          {:ok, js_expr} ->
            derive_name = "__attr_#{index}_#{attr_name}"
            [%{
              name: derive_name,
              js_expr: js_expr,
              deps: Enum.map(deps, &to_string/1),
              attr: attr_name
            }]

          :error ->
            []
        end
      else
        []
      end
    end)
  end

  defp try_transpile(expr) do
    js = Lavash.Rx.Transpiler.to_js(String.trim(expr))

    if js && !String.contains?(js, "undefined /* untranspilable") do
      {:ok, js}
    else
      :error
    end
  rescue
    _ -> :error
  end

  defp resolve_template_source(lavash_renders) do
    renders_map = Map.new(lavash_renders)

    case Map.get(renders_map, :__render_fn__) do
      nil -> nil
      escaped_fn -> extract_source(escaped_fn)
    end
  end

  defp extract_source({:fn, _, [{:->, _, [[_], body]}]}), do: extract_compiled_source(body)
  defp extract_source(_), do: nil

  defp extract_compiled_source({:sigil_L, _, [{:<<>>, _, [source]}, _]}) when is_binary(source), do: source
  defp extract_compiled_source({:%, _, [{:__aliases__, _, [:Lavash, :Template, :Compiled]}, {:%{}, _, fields}]}) do
    Keyword.get(fields, :source)
  end
  defp extract_compiled_source({:__block__, _, [inner]}), do: extract_compiled_source(inner)
  defp extract_compiled_source({:quote, _, [[do: ast]]}), do: extract_compiled_source(ast)
  defp extract_compiled_source(_), do: nil

end
