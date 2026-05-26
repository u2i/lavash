defmodule Lavash.Optimistic.Transformers.AnalyzeOptimisticTemplate do
  @moduledoc """
  Layer-4 template analysis: extracts the derives that drive
  client-side optimistic updates.

  Originally bundled into the layer-1
  `Lavash.Component.Transformers.AnalyzeTemplate`, then split out
  per `docs/ARCHITECTURE.md` punchlist item #4. This transformer
  has zero responsibility for layer-1 validation collection (which
  stays in `AnalyzeTemplate`) — it only walks the already-parsed
  template tree looking for optimistic-update opportunities and
  emits the JS-side metadata the colocated-JS extractor will
  consume.

  ## Outputs

    * `:lavash_attr_derives` — list of attr-derive specs
      (`disabled={...}`, `class={...}`, `hidden={...}` over
      optimistic-only deps) that the JS hook will re-evaluate
      client-side when a dep changes.

    * `:lavash_subtree_derives` — list of subtree-derive specs
      (`:if`/`:for` blocks over optimistic state) that the JS hook
      will re-render with `morphdom`-style patching.

    * Updated `:lavash_template_tokens` — the parser tree with
      `data-lavash-html` attributes injected onto subtree-derive
      parent nodes so the JS hook can locate them at runtime.

  ## Ordering

  Runs after `AnalyzeTemplate` (so the layer-1 validation data is
  already collected; we read the same `:lavash_template_tokens`)
  and before `ExtractColocatedJs` (which consumes our outputs to
  emit JS).
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  def after?(Lavash.Component.Transformers.AnalyzeTemplate), do: true
  def after?(_), do: false

  def before?(Lavash.Optimistic.Transformers.ExtractColocatedJs), do: true
  def before?(_), do: false

  def transform(dsl_state) do
    parsed = Transformer.get_persisted(dsl_state, :lavash_template_tokens)
    template_source = Transformer.get_persisted(dsl_state, :lavash_template_source)
    module = Transformer.get_persisted(dsl_state, :module)

    cond do
      is_nil(parsed) ->
        {:ok, dsl_state}

      # Layer-4 opt-out: see `Lavash.LiveView.Base`.
      module && Module.get_attribute(module, :__lavash_layer__) == :base ->
        {:ok, dsl_state}

      true ->
        do_transform(dsl_state, parsed, template_source)
    end
  end

  defp do_transform(dsl_state, parsed, template_source) do
    all_optimistic_names = build_optimistic_names(dsl_state)

    # Extract attr derives from the raw source string
    dsl_state = maybe_extract_attr_derives(dsl_state, template_source, all_optimistic_names)

    # Extract subtree derives and inject data-lavash-html onto block nodes
    {dsl_state, parsed} =
      extract_and_inject_subtree_derives(dsl_state, parsed, all_optimistic_names)

    # Persist updated parser tree (with data-lavash-html injections)
    dsl_state = Transformer.persist(dsl_state, :lavash_template_tokens, parsed)

    {:ok, dsl_state}
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
        map_bys = action.map_bys || []

        Enum.map(sets, & &1.field) ++ Enum.map(map_bys, & &1.field)
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

            [
              %{
                name: derive_name,
                js_expr: js_expr,
                deps: Enum.map(deps, &to_string/1),
                attr: attr_name
              }
            ]

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
    case Code.string_to_quoted(expr) do
      {:ok, ast} -> find_loop_variables(ast)
      _ -> false
    end
  end

  defp find_loop_variables({:@, _, _}), do: false

  defp find_loop_variables({name, _, context})
       when is_atom(name) and is_atom(context) and context != Elixir and
              name not in [:do, :else, :end, :fn, true, false, nil] do
    true
  end

  defp find_loop_variables({_, _, args}) when is_list(args) do
    Enum.any?(args, &find_loop_variables/1)
  end

  defp find_loop_variables(list) when is_list(list) do
    Enum.any?(list, &find_loop_variables/1)
  end

  defp find_loop_variables({left, right}) do
    find_loop_variables(left) or find_loop_variables(right)
  end

  defp find_loop_variables(_), do: false

  defp try_transpile(expr) do
    js = Lavash.Optimistic.Transpiler.to_js(String.trim(expr))

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

  defp extract_and_inject_subtree_derives(dsl_state, parsed, all_optimistic_names) do
    tree = Lavash.Template.parse(parsed)
    {derives_with_positions, _index} = find_parent_subtrees(tree, all_optimistic_names, [], 0)
    derives_with_positions = Enum.reverse(derives_with_positions)

    if derives_with_positions == [] do
      {dsl_state, parsed}
    else
      derives = Enum.map(derives_with_positions, &elem(&1, 0))

      position_to_derive =
        derives_with_positions
        |> Enum.map(fn {derive, {line, col}} -> {{line, col}, derive.name} end)
        |> Map.new()

      new_nodes = inject_data_lavash_html(parsed.nodes, position_to_derive)
      parsed = %{parsed | nodes: new_nodes}

      dsl_state = Transformer.persist(dsl_state, :lavash_subtree_derives, derives)
      {dsl_state, parsed}
    end
  end

  defp inject_data_lavash_html(nodes, position_to_derive) when is_list(nodes) do
    Enum.map(nodes, &inject_into_node(&1, position_to_derive))
  end

  defp inject_into_node(
         {:block, :tag, name, attrs, children, open_meta, close_meta},
         position_to_derive
       ) do
    new_attrs = maybe_add_lavash_html_attr(attrs, open_meta, position_to_derive)
    new_children = inject_data_lavash_html(children, position_to_derive)
    {:block, :tag, name, new_attrs, new_children, open_meta, close_meta}
  end

  defp inject_into_node(
         {:block, type, name, attrs, children, open_meta, close_meta},
         position_to_derive
       ) do
    new_children = inject_data_lavash_html(children, position_to_derive)
    {:block, type, name, attrs, new_children, open_meta, close_meta}
  end

  defp inject_into_node({:self_close, :tag, name, attrs, meta}, position_to_derive) do
    new_attrs = maybe_add_lavash_html_attr(attrs, meta, position_to_derive)
    {:self_close, :tag, name, new_attrs, meta}
  end

  defp inject_into_node({:eex_block, code, clauses, meta}, position_to_derive) do
    new_clauses =
      Enum.map(clauses, fn {clause_nodes, end_code, clause_meta} ->
        {inject_data_lavash_html(clause_nodes, position_to_derive), end_code, clause_meta}
      end)

    {:eex_block, code, new_clauses, meta}
  end

  defp inject_into_node(node, _position_to_derive), do: node

  defp maybe_add_lavash_html_attr(attrs, meta, position_to_derive) do
    key = {meta[:line], meta[:column]}

    case Map.get(position_to_derive, key) do
      nil ->
        attrs

      derive_name ->
        line = meta[:line] || 1
        column = meta[:column] || 1
        attr_meta = %{line: line, column: column}

        new_attr =
          {"data-lavash-html",
           {:string, derive_name, %{delimiter: ?", line: line, column: column}}, attr_meta}

        attrs ++ [new_attr]
    end
  end

  defp find_parent_subtrees(nodes, optimistic_names, acc, index) when is_list(nodes) do
    Enum.reduce(nodes, {acc, index}, fn node, {a, i} ->
      find_parent_subtrees(node, optimistic_names, a, i)
    end)
  end

  defp find_parent_subtrees(
         {:element, _tag, _attrs, children, meta},
         optimistic_names,
         acc,
         index
       ) do
    if has_optimistic_child?(children, optimistic_names) do
      children_js = Enum.map_join(children, "", &Lavash.Component.JsGenerator.subtree_to_js/1)

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

        _ ->
          []
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
