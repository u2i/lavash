defmodule Lavash.Optimistic.DefrxExpander do
  @moduledoc """
  Spark transformer that expands defrx function calls in rx expressions.

  This transformer runs early and expands any defrx calls in calculation rx.ast
  values, ensuring both server-side Elixir evaluation and JS transpilation work.
  """

  use Spark.Dsl.Transformer

  # Run before ColocatedTransformer
  def after?(_), do: false
  def before?(Lavash.Optimistic.ColocatedTransformer), do: true
  def before?(_), do: false

  @doc """
  Transform the DSL state by expanding defrx calls in calculation rx ASTs.
  """
  def transform(dsl_state) do
    # Get the defrx definitions from module attributes
    defrx_map = get_defrx_map(dsl_state)

    # If no defrx definitions, skip transformation
    if map_size(defrx_map) == 0 do
      {:ok, dsl_state}
    else
      # Transform all calculations to expand defrx calls in their rx.ast
      expand_calculations(dsl_state, defrx_map)
    end
  end

  # Get defrx definitions from module attributes (local and imported)
  defp get_defrx_map(dsl_state) do
    env = Spark.Dsl.Transformer.get_persisted(dsl_state, :env)

    if env do
      # Get local defrx definitions
      # Format: {name, arity, params, body_ast, body_source}
      local_defs = Module.get_attribute(env.module, :lavash_defrx) || []

      # Get imported defrx definitions
      imports = Module.get_attribute(env.module, :lavash_defrx_imports) || []
      imported_defs = collect_imported_defrx(imports)

      # Build map with imports first, then locals (locals override imports)
      Enum.reduce(imported_defs ++ local_defs, %{}, fn {name, arity, params, body_ast, _body_source}, acc ->
        Map.put(acc, {name, arity}, {params, body_ast})
      end)
    else
      %{}
    end
  end

  # Collect defrx definitions from imported modules
  defp collect_imported_defrx(imports) do
    Enum.flat_map(imports, fn {module, opts} ->
      try do
        defs = module.__defrx_definitions__()

        case Keyword.get(opts, :only) do
          nil ->
            defs

          only_list ->
            Enum.filter(defs, fn {name, arity, _, _, _} ->
              {name, arity} in only_list
            end)
        end
      rescue
        UndefinedFunctionError ->
          # Module doesn't export defrx definitions
          []
      end
    end)
  end

  # Expand defrx calls in all calculations
  defp expand_calculations(dsl_state, defrx_map) do
    calculations = Spark.Dsl.Transformer.get_entities(dsl_state, [:calculations]) || []

    # Remove all calculations and add expanded versions
    dsl_state =
      Enum.reduce(calculations, dsl_state, fn calc, state ->
        Spark.Dsl.Transformer.remove_entity(state, [:calculations], fn c -> c.name == calc.name end)
      end)

    dsl_state =
      Enum.reduce(calculations, dsl_state, fn calc, state ->
        expanded_ast = expand_defrx_in_ast(calc.rx.ast, defrx_map)
        expanded_source = expand_defrx_in_source(calc.rx.source, defrx_map)

        updated_rx = %{calc.rx | ast: expanded_ast, source: expanded_source}
        updated_calc = %{calc | rx: updated_rx}

        Spark.Dsl.Transformer.add_entity(state, [:calculations], updated_calc)
      end)

    # Also expand defrx in extend_errors conditions
    extend_errors = Spark.Dsl.Transformer.get_entities(dsl_state, [:extend_errors_declarations]) || []

    dsl_state =
      Enum.reduce(extend_errors, dsl_state, fn ext, state ->
        Spark.Dsl.Transformer.remove_entity(state, [:extend_errors_declarations], fn e -> e.field == ext.field end)
      end)

    dsl_state =
      Enum.reduce(extend_errors, dsl_state, fn ext, state ->
        updated_errors =
          Enum.map(ext.errors, fn error ->
            expanded_ast = expand_defrx_in_ast(error.condition.ast, defrx_map)
            expanded_source = expand_defrx_in_source(error.condition.source, defrx_map)

            updated_condition = %{error.condition | ast: expanded_ast, source: expanded_source}

            # Also expand message if it's an rx
            updated_message =
              case error.message do
                %Lavash.Rx{} = rx ->
                  expanded_msg_ast = expand_defrx_in_ast(rx.ast, defrx_map)
                  expanded_msg_source = expand_defrx_in_source(rx.source, defrx_map)
                  %{rx | ast: expanded_msg_ast, source: expanded_msg_source}

                other ->
                  other
              end

            %{error | condition: updated_condition, message: updated_message}
          end)

        updated_ext = %{ext | errors: updated_errors}
        Spark.Dsl.Transformer.add_entity(state, [:extend_errors_declarations], updated_ext)
      end)

    {:ok, dsl_state}
  end

  # Expand defrx calls in an AST
  defp expand_defrx_in_ast(ast, defrx_map) do
    do_expand_ast(ast, defrx_map)
  end

  defp do_expand_ast({name, meta, args}, defrx_map) when is_atom(name) and is_list(args) do
    arity = length(args)
    expanded_args = Enum.map(args, &do_expand_ast(&1, defrx_map))

    case Map.get(defrx_map, {name, arity}) do
      {params, body_ast} ->
        # Substitute params with args in the body
        substitutions = Enum.zip(params, expanded_args) |> Map.new()
        substituted = substitute_vars(body_ast, substitutions)
        # Recursively expand any nested defrx calls in the substituted body
        do_expand_ast(substituted, defrx_map)

      nil ->
        {name, meta, expanded_args}
    end
  end

  defp do_expand_ast({form, meta, args}, defrx_map) when is_list(args) do
    {do_expand_ast(form, defrx_map), meta, Enum.map(args, &do_expand_ast(&1, defrx_map))}
  end

  defp do_expand_ast({left, right}, defrx_map) do
    {do_expand_ast(left, defrx_map), do_expand_ast(right, defrx_map)}
  end

  defp do_expand_ast(list, defrx_map) when is_list(list) do
    Enum.map(list, &do_expand_ast(&1, defrx_map))
  end

  defp do_expand_ast(other, _defrx_map), do: other

  # Substitute variable references with their values
  defp substitute_vars({var_name, meta, context}, substitutions) when is_atom(var_name) and is_atom(context) do
    case Map.get(substitutions, var_name) do
      nil -> {var_name, meta, context}
      value -> value
    end
  end

  defp substitute_vars({form, meta, args}, substitutions) when is_list(args) do
    {substitute_vars(form, substitutions), meta, Enum.map(args, &substitute_vars(&1, substitutions))}
  end

  defp substitute_vars({left, right}, substitutions) do
    {substitute_vars(left, substitutions), substitute_vars(right, substitutions)}
  end

  defp substitute_vars(list, substitutions) when is_list(list) do
    Enum.map(list, &substitute_vars(&1, substitutions))
  end

  defp substitute_vars(other, _substitutions), do: other

  # Expand defrx calls in source string
  defp expand_defrx_in_source(source, defrx_map) when map_size(defrx_map) == 0, do: source

  defp expand_defrx_in_source(source, defrx_map) do
    case Code.string_to_quoted(source) do
      {:ok, ast} ->
        expanded_ast = do_expand_ast(ast, defrx_map)
        Macro.to_string(expanded_ast)

      {:error, _} ->
        source
    end
  end
end
