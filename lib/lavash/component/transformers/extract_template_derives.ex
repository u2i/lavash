defmodule Lavash.Component.Transformers.ExtractTemplateDerives do
  @moduledoc """
  Spark transformer that extracts optimistic derives from component templates.

  Scans the template for:
  - **Attr derives** (`data-lavash-attr-*`): attributes like `class={expr}` or
    `disabled={expr}` that reference optimistic calculations
  - **Subtree derives** (`data-lavash-html`): `:if`/`:for` elements that
    reference optimistic state, transpiled to small JS render functions

  These derives are persisted to DSL state for consumption by
  `ExtractColocatedJs` (JS generation) and `TokenTransformer` (attribute injection).
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

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
      lavash_renders = Module.get_attribute(env.module, :__lavash_renders__) || []
      {template_source, sigil_line} = resolve_template_source_and_line(lavash_renders)

      if is_nil(template_source) do
        {:ok, dsl_state}
      else
        # Build set of all optimistic names (calculations, form derives, action target fields)
        all_optimistic_names = build_optimistic_names(dsl_state)

        # Tokenize once with file-absolute line numbers
        tokens = Lavash.Template.tokenize(template_source,
          line: (sigil_line || 0) + 1,
          file: env.file
        )

        # Extract attr derives (data-lavash-attr-*) from the raw source
        dsl_state = maybe_extract_attr_derives(dsl_state, template_source, all_optimistic_names)

        # Extract subtree derives and inject data-lavash-html onto tokens
        {dsl_state, tokens} = extract_and_inject_subtree_derives(dsl_state, tokens, all_optimistic_names)

        # Persist tokens and source for ExtractColocatedJs to compile via TagEngine
        dsl_state = Transformer.persist(dsl_state, :lavash_template_tokens, tokens)
        dsl_state = Transformer.persist(dsl_state, :lavash_template_source, template_source)

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

  # Extract subtree derives from the token tree AND inject data-lavash-html
  # attributes directly onto the tokens. Single tokenization, single tree walk.
  defp extract_and_inject_subtree_derives(dsl_state, tokens, all_optimistic_names) do
    tree = Lavash.Template.parse(tokens)
    {derives_with_positions, _index} = find_parent_subtrees(tree, all_optimistic_names, [], 0)
    derives_with_positions = Enum.reverse(derives_with_positions)

    if derives_with_positions == [] do
      {dsl_state, tokens}
    else
      derives = Enum.map(derives_with_positions, &elem(&1, 0))

      # Build lookup: {line, column} => derive_name for token injection
      position_to_derive =
        derives_with_positions
        |> Enum.map(fn {derive, {line, col}} -> {{line, col}, derive.name} end)
        |> Map.new()

      # Inject data-lavash-html attributes onto parent tokens
      tokens =
        Enum.map(tokens, fn
          {:tag, name, attrs, meta} = token ->
            key = {meta[:line], meta[:column]}
            case Map.get(position_to_derive, key) do
              nil -> token
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
        deps: all_deps |> Enum.map(&to_string/1) |> Enum.uniq()
      }

      position = {meta[:line], meta[:column]}
      {[{derive, position} | acc], index + 1}
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

  defp resolve_template_source_and_line(lavash_renders) do
    renders_map = Map.new(lavash_renders)

    case Map.get(renders_map, :__render_fn__) do
      nil -> {nil, nil}
      escaped_fn -> extract_source_and_line(escaped_fn)
    end
  end

  defp extract_source_and_line({:fn, _, [{:->, _, [[_], body]}]}), do: extract_compiled_source_and_line(body)
  defp extract_source_and_line(_), do: {nil, nil}

  defp extract_compiled_source_and_line({:sigil_L, meta, [{:<<>>, _, [source]}, _]}) when is_binary(source) do
    {source, Keyword.get(meta, :line)}
  end
  defp extract_compiled_source_and_line({:%, _, [{:__aliases__, _, [:Lavash, :Template, :Compiled]}, {:%{}, _, fields}]}) do
    {Keyword.get(fields, :source), nil}
  end
  defp extract_compiled_source_and_line({:__block__, _, [inner]}), do: extract_compiled_source_and_line(inner)
  defp extract_compiled_source_and_line({:quote, _, [[do: ast]]}), do: extract_compiled_source_and_line(ast)
  defp extract_compiled_source_and_line(_), do: {nil, nil}

end
