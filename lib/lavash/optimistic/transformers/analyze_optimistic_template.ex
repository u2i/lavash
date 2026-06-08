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
        do_transform(dsl_state, parsed, template_source, module)
    end
  end

  defp do_transform(dsl_state, parsed, template_source, module) do
    all_optimistic_names = build_optimistic_names(dsl_state)
    defrx_map = Lavash.Optimistic.Transformers.ExpandDefrx.get_defrx_map(dsl_state)

    # Extract attr derives from the raw source string
    dsl_state = maybe_extract_attr_derives(dsl_state, template_source, all_optimistic_names)

    # Extract subtree derives and inject data-lavash-html onto block nodes.
    # This also validates that every optimistic-dependent expression in a
    # transpiled subtree CAN be transpiled — an untranspilable one raises a
    # compile-time DslError rather than emitting broken JS at esbuild time.
    case extract_and_inject_subtree_derives(
           dsl_state,
           parsed,
           all_optimistic_names,
           defrx_map,
           module
         ) do
      {:ok, dsl_state, parsed} ->
        dsl_state = Transformer.persist(dsl_state, :lavash_template_tokens, parsed)
        {:ok, dsl_state}

      {:error, dsl_error} ->
        {:error, dsl_error}
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

    # State fields declared `optimistic: true` (or `animated`). These can be
    # read directly in `:if`/`:for`/`{...}` and drive client re-renders even
    # when no action/calc references them.
    state_names =
      (Transformer.get_entities(dsl_state, [:states]) || [])
      |> Enum.filter(&Lavash.State.Field.optimistic?/1)
      |> Enum.map(& &1.name)

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

    MapSet.new(calc_names ++ state_names ++ form_derive_names ++ action_field_names)
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

  # ============================================
  # Loop-aware optimistic-dependency analysis
  # ============================================
  #
  # Whether a template expression "needs" client transpilation is decided by
  # whether it (transitively) references optimistic state. `@field` refs are
  # checked against the optimistic field names; bare loop variables are
  # checked against `optimistic_loop_vars` — the set of `:for` binding vars
  # whose SOURCE list is itself optimistic-derived. A loop var over a static
  # list never changes on the client, so refs to it are server-only.

  # Parse a `:for={x <- src}` (or `:for={x <- src, filter}`) generator into
  # `{var_atom, collection_ast}`. Returns nil if it isn't a single-binding
  # comprehension generator we can reason about.
  defp parse_for_binding(code) do
    case Code.string_to_quoted(code) do
      {:ok, {:<-, _, [{var, _, ctx}, collection]}} when is_atom(var) and is_atom(ctx) ->
        {var, collection}

      _ ->
        nil
    end
  end

  # Does `code` (a template expression string) reference any optimistic state?
  defp expr_references_optimistic?(code, optimistic_names, optimistic_loop_vars) do
    case Code.string_to_quoted(code) do
      {:ok, ast} -> ast_references_optimistic?(ast, optimistic_names, optimistic_loop_vars)
      _ -> false
    end
  end

  # @field where field is optimistic
  defp ast_references_optimistic?({:@, _, [{name, _, _}]}, names, _loop_vars)
       when is_atom(name) do
    MapSet.member?(names, name)
  end

  # bare variable that is bound to an optimistic loop source
  defp ast_references_optimistic?({name, _, ctx}, _names, loop_vars)
       when is_atom(name) and is_atom(ctx) do
    MapSet.member?(loop_vars, name)
  end

  defp ast_references_optimistic?({_, _, args}, names, loop_vars) when is_list(args) do
    Enum.any?(args, &ast_references_optimistic?(&1, names, loop_vars))
  end

  defp ast_references_optimistic?(list, names, loop_vars) when is_list(list) do
    Enum.any?(list, &ast_references_optimistic?(&1, names, loop_vars))
  end

  defp ast_references_optimistic?({left, right}, names, loop_vars) do
    ast_references_optimistic?(left, names, loop_vars) or
      ast_references_optimistic?(right, names, loop_vars)
  end

  defp ast_references_optimistic?(_, _names, _loop_vars), do: false

  # The optimistic `@`-field names actually referenced by `code`, given the
  # current loop-var scope. These are the concrete deps the JS hook subscribes
  # to. Loop vars are not deps themselves — their backing `@`-source is.
  defp collect_optimistic_refs(code, optimistic_names, optimistic_loop_vars) do
    case Code.string_to_quoted(code) do
      {:ok, ast} -> collect_ast_optimistic_refs(ast, optimistic_names, optimistic_loop_vars)
      _ -> []
    end
  end

  defp collect_ast_optimistic_refs({:@, _, [{name, _, _}]}, names, _loop_vars)
       when is_atom(name) do
    if MapSet.member?(names, name), do: [name], else: []
  end

  defp collect_ast_optimistic_refs({_, _, args}, names, loop_vars) when is_list(args) do
    Enum.flat_map(args, &collect_ast_optimistic_refs(&1, names, loop_vars))
  end

  defp collect_ast_optimistic_refs(list, names, loop_vars) when is_list(list) do
    Enum.flat_map(list, &collect_ast_optimistic_refs(&1, names, loop_vars))
  end

  defp collect_ast_optimistic_refs({left, right}, names, loop_vars) do
    collect_ast_optimistic_refs(left, names, loop_vars) ++
      collect_ast_optimistic_refs(right, names, loop_vars)
  end

  defp collect_ast_optimistic_refs(_, _names, _loop_vars), do: []

  # ============================================
  # Transpilability oracle (defrx-aware)
  # ============================================
  #
  # An expression that must run on the client (it depends on optimistic state)
  # has to be transpilable to JS. defrx helpers ARE transpilable — expand them
  # first, then validate the resulting AST. Returns :ok | {:error, reason}.
  defp template_expr_transpilable?(code, defrx_map) do
    case Code.string_to_quoted(code) do
      {:ok, ast} ->
        ast
        |> Lavash.Optimistic.Transformers.ExpandDefrx.expand_defrx_in_ast(defrx_map)
        |> Lavash.Optimistic.Transpiler.validate_ast()

      {:error, _} ->
        {:error, "unparseable expression"}
    end
  end

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

  defp extract_and_inject_subtree_derives(
         dsl_state,
         parsed,
         all_optimistic_names,
         defrx_map,
         module
       ) do
    tree = Lavash.Template.parse(parsed)

    # The subtree walk validates each optimistic-dependent expression as it
    # goes; an untranspilable one is thrown as `{:lavash_untranspilable, ...}`
    # and converted to a compile-time DslError here.
    ctx = %{names: all_optimistic_names, defrx_map: defrx_map, module: module}

    try do
      {derives_with_positions, _index} =
        find_parent_subtrees(tree, ctx, MapSet.new(), [], 0)

      derives_with_positions = Enum.reverse(derives_with_positions)
      {dsl_state, parsed} = finish_subtree_derives(dsl_state, parsed, derives_with_positions)
      {:ok, dsl_state, parsed}
    catch
      {:lavash_untranspilable, dsl_error} -> {:error, dsl_error}
    end
  end

  defp finish_subtree_derives(dsl_state, parsed, derives_with_positions) do
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

  defp find_parent_subtrees(nodes, ctx, loop_vars, acc, index)
       when is_list(nodes) do
    Enum.reduce(nodes, {acc, index}, fn node, {a, i} ->
      find_parent_subtrees(node, ctx, loop_vars, a, i)
    end)
  end

  defp find_parent_subtrees(
         {:element, _tag, attrs, children, meta},
         ctx,
         loop_vars,
         acc,
         index
       ) do
    # Extend the optimistic-loop-var scope for this element's children if it
    # carries a `:for` whose source list is optimistic-derived.
    child_loop_vars = extend_loop_scope(attrs, ctx.names, loop_vars)

    if has_optimistic_child?(children, ctx.names, child_loop_vars) do
      # This subtree will be transpiled and re-rendered on the client. Every
      # optimistic-dependent expression in it MUST be transpilable, or we emit
      # broken JS at esbuild time. Validate now; throw on the first failure.
      validate_subtree_transpilable!(children, ctx, child_loop_vars)

      children_js = Enum.map_join(children, "", &Lavash.Component.JsGenerator.subtree_to_js/1)

      derive_name = "__subtree_#{index}"
      all_deps = collect_all_optimistic_deps(children, ctx.names, child_loop_vars)

      derive = %{
        name: derive_name,
        js_expr: "`#{children_js}`",
        deps: all_deps |> Enum.map(&to_string/1) |> Enum.uniq()
      }

      position = {meta[:line], meta[:column]}
      {[{derive, position} | acc], index + 1}
    else
      find_parent_subtrees(children, ctx, child_loop_vars, acc, index)
    end
  end

  defp find_parent_subtrees(_node, _ctx, _loop_vars, acc, index),
    do: {acc, index}

  # Walk an optimistic subtree and ensure every optimistic-dependent expression
  # (interpolations + `:if`/`:for`/attr exprs) is transpilable. Throws
  # `{:lavash_untranspilable, %DslError{}}` on the first that isn't.
  defp validate_subtree_transpilable!(nodes, ctx, loop_vars) when is_list(nodes) do
    Enum.each(nodes, &validate_subtree_transpilable!(&1, ctx, loop_vars))
  end

  defp validate_subtree_transpilable!({:element, _tag, attrs, children, _meta}, ctx, loop_vars) do
    child_loop_vars = extend_loop_scope(attrs, ctx.names, loop_vars)

    Enum.each(attrs, fn
      # `:for={x <- src}` is a generator, not a JS-able value expression — its
      # dependency is handled via loop-scope, and JsGenerator parses it
      # specially. Skip it (validating `x <- src` would wrongly reject `<-`).
      {":for", _} ->
        :ok

      # `:if={cond}` IS transpiled (the client evaluates the condition), so it
      # must be validated like any other expression.
      {_name, {:expr, code, meta}} ->
        check_expr_transpilable!(code, meta, ctx, loop_vars)

      _ ->
        :ok
    end)

    validate_subtree_transpilable!(children, ctx, child_loop_vars)
  end

  defp validate_subtree_transpilable!({:expr, code, meta}, ctx, loop_vars) do
    check_expr_transpilable!(code, meta, ctx, loop_vars)
  end

  defp validate_subtree_transpilable!(_node, _ctx, _loop_vars), do: :ok

  # Only optimistic-dependent expressions need to transpile; server-only
  # expressions (no optimistic refs) are left to the server renderer.
  defp check_expr_transpilable!(code, meta, ctx, loop_vars) do
    if expr_references_optimistic?(code, ctx.names, loop_vars) do
      case template_expr_transpilable?(code, ctx.defrx_map) do
        :ok ->
          :ok

        {:error, reason} ->
          throw({:lavash_untranspilable, untranspilable_error(code, reason, meta, ctx.module)})
      end
    end
  end

  defp untranspilable_error(code, reason, meta, module) do
    line_hint =
      case meta do
        %{line: line} -> " (line #{line})"
        _ -> ""
      end

    %Spark.Error.DslError{
      module: module,
      path: [:template],
      message: """
      Cannot transpile `#{String.trim(code)}`#{line_hint} to client JS.

      This expression depends on optimistic state, so lavash must re-render it
      on the client — but `#{reason}` has no JS equivalent. (Only expressions
      lavash can transpile may depend on optimistic state inside an
      optimistically-updated subtree.)

      Either:

        - Move the derived value into a `calculate :name, rx(...)` and reference
          `@name` in the template. The `rx(...)` body may call `defrx` helpers
          (`defrx name(args), do: ...`, or `import_rx` from another module),
          which lavash transpiles to JS.
        - Drop the optimistic dependency (don't reference optimistic state here)
          so the expression is server-rendered only.
      """
    }
  end

  # If `attrs` includes `:for={x <- src}` and `src` is optimistic-derived in
  # the current scope, add `x` to the loop-var scope for the children.
  defp extend_loop_scope(attrs, optimistic_names, loop_vars) do
    case Enum.find(attrs, fn {name, _} -> name == ":for" end) do
      {":for", {:expr, code, _meta}} ->
        case parse_for_binding(code) do
          {var, collection} ->
            collection_src = Macro.to_string(collection)

            if expr_references_optimistic?(collection_src, optimistic_names, loop_vars) do
              MapSet.put(loop_vars, var)
            else
              loop_vars
            end

          nil ->
            loop_vars
        end

      _ ->
        loop_vars
    end
  end

  defp has_optimistic_child?(children, optimistic_names, loop_vars) do
    Enum.any?(children, fn
      {:element, _tag, attrs, _children, _meta} ->
        match?({:ok, _}, optimistic_conditional(attrs, optimistic_names, loop_vars))

      _ ->
        false
    end)
  end

  defp optimistic_conditional(attrs, optimistic_names, loop_vars) do
    conditional_attr =
      Enum.find(attrs, fn
        {":if", {:expr, _code, _meta}} -> true
        {":for", {:expr, _code, _meta}} -> true
        _ -> false
      end)

    case conditional_attr do
      {_name, {:expr, code, _meta}} ->
        deps = collect_optimistic_refs(code, optimistic_names, loop_vars)
        if deps != [], do: {:ok, deps}, else: :skip

      _ ->
        :skip
    end
  end

  defp collect_all_optimistic_deps(nodes, optimistic_names, loop_vars) when is_list(nodes) do
    Enum.flat_map(nodes, &collect_all_optimistic_deps(&1, optimistic_names, loop_vars))
  end

  defp collect_all_optimistic_deps(
         {:element, _tag, attrs, children, _meta},
         optimistic_names,
         loop_vars
       ) do
    # An element's own `:for` can introduce a loop var for its children.
    child_loop_vars = extend_loop_scope(attrs, optimistic_names, loop_vars)

    attr_deps =
      Enum.flat_map(attrs, fn
        {_name, {:expr, code, _meta}} ->
          collect_optimistic_refs(code, optimistic_names, loop_vars)

        _ ->
          []
      end)

    attr_deps ++ collect_all_optimistic_deps(children, optimistic_names, child_loop_vars)
  end

  defp collect_all_optimistic_deps({:expr, code, _meta}, optimistic_names, loop_vars) do
    collect_optimistic_refs(code, optimistic_names, loop_vars)
  end

  defp collect_all_optimistic_deps(_node, _optimistic_names, _loop_vars), do: []
end
