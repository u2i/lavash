defmodule Lavash.ClientComponent.Macros do
  @moduledoc """
  Macros for ClientComponent that need to be imported.

  These are separate from the main module to avoid circular dependency issues
  with Spark DSL compilation.
  """

  @doc """
  Defines a calculated field that runs on both server and client.

  The expression is compiled to both Elixir (for server rendering) and JavaScript
  (for optimistic client-side updates). The expression can reference:
  - `@field` - state fields (e.g., `@selected`, `@values`)
  - Common functions: `length/1`, `Enum.count/1`, `Enum.join/2`, `Map.get/2,3`

  ## Example

      calculate :can_add, @max_tags == nil or length(@tags) < @max_tags
      calculate :tag_count, length(@tags)
  """
  defmacro calculate(name, expr) do
    # Convert the AST to source string before quote (for JS generation)
    expr_source = Macro.to_string(expr)

    # Transform @var references in the AST to Map.get(state, :var) for runtime evaluation
    transformed_expr = transform_at_refs(expr)

    quote do
      @__lavash_calculations__ {unquote(name), unquote(expr_source), unquote(Macro.escape(transformed_expr))}
    end
  end

  @doc """
  Defines an optimistic action that runs on both server and client.

  This macro captures the source code of the `run` and `validate` functions
  for JavaScript compilation, then stores the action in a module attribute.

  ## Example

      optimistic_action :add, :tags,
        run: fn tags, tag -> tags ++ [tag] end,
        validate: fn tags, tag -> tag not in tags end,
        max: :max_tags
  """
  defmacro optimistic_action(name, field, opts) do
    # Extract run and validate from opts and convert to source strings
    run_expr = Keyword.get(opts, :run)
    validate_expr = Keyword.get(opts, :validate)

    run_source = if run_expr, do: Macro.to_string(run_expr), else: nil
    validate_source = if validate_expr, do: Macro.to_string(validate_expr), else: nil

    max_field = Keyword.get(opts, :max)

    # Store action data in module attribute for later retrieval by compiler
    # We only store serializable data (atoms, strings) - functions are regenerated from source
    quote do
      @__lavash_optimistic_actions__ {
        unquote(name),
        unquote(field),
        unquote(run_source),
        unquote(validate_source),
        unquote(max_field)
      }
    end
  end

  # Transform @var references to Map.get(state, :var) for runtime evaluation
  # Use Macro.var to create a variable without macro hygiene context
  defp transform_at_refs({:@, _, [{var_name, _, _}]}) when is_atom(var_name) do
    state_var = Macro.var(:state, nil)
    quote do: Map.get(unquote(state_var), unquote(var_name), nil)
  end

  defp transform_at_refs({form, meta, args}) when is_list(args) do
    {form, meta, Enum.map(args, &transform_at_refs/1)}
  end

  defp transform_at_refs({left, right}) do
    {transform_at_refs(left), transform_at_refs(right)}
  end

  defp transform_at_refs(list) when is_list(list) do
    Enum.map(list, &transform_at_refs/1)
  end

  defp transform_at_refs(other), do: other
end
