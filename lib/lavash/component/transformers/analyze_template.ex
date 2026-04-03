defmodule Lavash.Component.Transformers.AnalyzeTemplate do
  @moduledoc """
  Analyzes pre-tokenized template tokens for optimistic derives.

  Reads tokens from `:lavash_template_tokens`, parses into a tree, and:
  - Extracts **subtree derives** (JS render functions for `:if`/`:for` over optimistic state)
  - Extracts **attr derives** (`disabled={expr}`, `class={expr}` over optimistic fields)
  - Injects `data-lavash-html` attributes directly onto parent tokens

  Persists:
  - `:lavash_subtree_derives` — subtree derive metadata (name, js_expr, deps)
  - `:lavash_attr_derives` — attr derive metadata (name, js_expr, deps, attr)
  - `:lavash_template_tokens` — updated tokens with `data-lavash-html` injected
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  def after?(Lavash.Component.Transformers.TokenizeTemplate), do: true
  def after?(Lavash.Optimistic.Transformers.ExpandAnimatedStates), do: true
  def after?(Lavash.Transformers.ExpandFields), do: true
  def after?(_), do: false

  def before?(Lavash.Optimistic.Transformers.ExtractColocatedJs), do: true
  def before?(_), do: false

  def transform(dsl_state) do
    tokens = Transformer.get_persisted(dsl_state, :lavash_template_tokens)
    template_source = Transformer.get_persisted(dsl_state, :lavash_template_source)

    if is_nil(tokens) do
      {:ok, dsl_state}
    else
      all_optimistic_names = build_optimistic_names(dsl_state)

      # Extract attr derives from the raw source string
      dsl_state = maybe_extract_attr_derives(dsl_state, template_source, all_optimistic_names)

      # Extract subtree derives and inject data-lavash-html onto tokens
      {dsl_state, tokens} = extract_and_inject_subtree_derives(dsl_state, tokens, all_optimistic_names)

      # Persist updated tokens
      dsl_state = Transformer.persist(dsl_state, :lavash_template_tokens, tokens)

      {:ok, dsl_state}
    end
  end

  # ============================================
  # Optimistic name collection
  # ============================================

  defp build_optimistic_names(dsl_state) do
    calculations =
      (Transformer.get_entities(dsl_state, [:calculations]) || [])
      |> Enum.filter(&Map.get(&1, :optimistic, true))

    calc_names = Enum.map(calculations, & &1.name)

    forms = Transformer.get_entities(dsl_state, [:forms]) || []
    form_derive_names = Enum.map(forms, fn f -> :"#{f.name}_valid" end)

    actions = Transformer.get_entities(dsl_state, [:actions]) || []
    action_field_names =
      actions
      |> Enum.flat_map(fn action ->
        sets = action.sets || []
        updates = action.updates || []
        map_bys = action.map_bys || []
        Enum.map(sets, & &1.field) ++ Enum.map(updates, & &1.field) ++ Enum.map(map_bys, & &1.field)
      end)

    MapSet.new(calc_names ++ form_derive_names ++ action_field_names)
  end

  # ============================================
  # Attr derive extraction
  # ============================================

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

  defp extract_attr_derives(template_source, optimistic_names) do
    Regex.scan(~r/(disabled|class|hidden)=\{([^}]+)\}/, template_source)
    |> Enum.with_index()
    |> Enum.flat_map(fn {[_full, attr_name, expr], index} ->
      deps =
        Regex.scan(~r/@(\w+)/, expr)
        |> Enum.map(fn [_, field] -> String.to_atom(field) end)
        |> Enum.filter(&MapSet.member?(optimistic_names, &1))
        |> Enum.uniq()

      if deps != [] and not has_loop_variables?(expr) do
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

  # Detect expressions that reference loop variables (bare identifiers not prefixed with @).
  # These can't be transpiled to JS derives because the loop variable doesn't exist in derive scope.
  defp has_loop_variables?(expr) do
    # Parse the expression and look for bare variable references
    case Code.string_to_quoted(expr) do
      {:ok, ast} ->
        {_, has_bare} =
          Macro.prewalk(ast, false, fn
            # @field references are fine (they become state.field in JS)
            {:@, _, _} = node, acc -> {node, acc}
            # Bare variable reference — this is a loop variable
            {name, _, context} = node, _acc when is_atom(name) and is_atom(context) and context != Elixir and name not in [:do, :else, :end, :fn, :true, :false, :nil] ->
              {node, true}
            node, acc -> {node, acc}
          end)

        has_bare

      _ ->
        false
    end
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

  # ============================================
  # Subtree derive extraction + token injection
  # ============================================

  defp extract_and_inject_subtree_derives(dsl_state, tokens, all_optimistic_names) do
    tree = Lavash.Template.parse(tokens)
    {derives_with_positions, _index} = find_parent_subtrees(tree, all_optimistic_names, [], 0)
    derives_with_positions = Enum.reverse(derives_with_positions)

    if derives_with_positions == [] do
      {dsl_state, tokens}
    else
      derives = Enum.map(derives_with_positions, &elem(&1, 0))

      position_to_derive =
        derives_with_positions
        |> Enum.map(fn {derive, {line, col}} -> {{line, col}, derive.name} end)
        |> Map.new()

      tokens =
        Enum.map(tokens, fn
          {:tag, name, attrs, meta} = _token ->
            key = {meta[:line], meta[:column]}
            case Map.get(position_to_derive, key) do
              nil -> {:tag, name, attrs, meta}
              derive_name ->
                attr_meta = %{line: meta[:line] || 1, column: meta[:column] || 1}
                new_attr = {"data-lavash-html",
                  {:string, derive_name, %{delimiter: ?", line: attr_meta.line, column: attr_meta.column}},
                  attr_meta}
                {:tag, name, attrs ++ [new_attr], meta}
            end

          token -> token
        end)

      dsl_state = Transformer.persist(dsl_state, :lavash_subtree_derives, derives)
      {dsl_state, tokens}
    end
  end

  defp find_parent_subtrees(nodes, optimistic_names, acc, index) when is_list(nodes) do
    Enum.reduce(nodes, {acc, index}, fn node, {a, i} ->
      find_parent_subtrees(node, optimistic_names, a, i)
    end)
  end

  defp find_parent_subtrees({:element, _tag, _attrs, children, meta}, optimistic_names, acc, index) do
    if has_optimistic_child?(children, optimistic_names) do
      children_js =
        children
        |> Enum.map(&Lavash.Component.JsGenerator.subtree_to_js/1)
        |> Enum.join("")

      derive_name = "__subtree_#{index}"
      all_deps = collect_all_optimistic_deps(children, optimistic_names)

      derive = %{
        name: derive_name,
        js_expr: "`#{children_js}`",
        deps: all_deps |> Enum.map(&to_string/1) |> Enum.uniq()
      }

      position = {meta[:line], meta[:column]}
      {[{derive, position} | acc], index + 1}
    else
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
end
