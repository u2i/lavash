defmodule Lavash.Optimistic.Macros do
  @moduledoc """
  Shared macros for isomorphic optimistic updates.

  These macros capture expression source code at compile time, allowing
  transpilation to both Elixir (server) and JavaScript (client).

  Used by LiveView, LiveComponent, and ClientComponent.

  ## Example

      defmodule MyLive do
        use Lavash.LiveView

        state :tags, {:array, :string}, optimistic: true

        # Simple transpilable calculation
        calculate :tag_count, length(@tags)
        calculate :has_tags, length(@tags) > 0
      end
  """

  @doc """
  Defines a calculated field that runs on both server and client.

  The expression is compiled to both Elixir (for server rendering) and JavaScript
  (for optimistic client-side updates). The expression can reference:
  - `@field` - state fields (e.g., `@tags`, `@count`)
  - Common functions: `length/1`, `Enum.count/1`, `Enum.join/2`, `Map.get/2,3`

  ## Supported expressions

  Simple expressions that can be transpiled:
  - Arithmetic: `@count + 1`, `@price * @quantity`
  - Comparisons: `@count > 0`, `@name == "test"`
  - Boolean: `@enabled and @visible`, `not @disabled`
  - Conditionals: `if(@count > 0, do: "yes", else: "no")`
  - List operations: `length(@items)`, `@items ++ ["new"]`

  ## Example

      calculate :can_add, @max_tags == nil or length(@tags) < @max_tags
      calculate :tag_count, length(@tags)
      calculate :summary, if(length(@tags) == 0, do: "No tags", else: "\#{length(@tags)} tags")
  """
  defmacro calculate(name, expr) do
    # Convert the AST to source string before quote (for JS generation)
    expr_source = Macro.to_string(expr)

    # Transform @var references in the AST to state access for runtime evaluation
    transformed_expr = transform_at_refs(expr)

    # Extract dependencies from @var references
    deps = extract_deps(expr)

    quote do
      @__lavash_calculations__ {
        unquote(name),
        unquote(expr_source),
        unquote(Macro.escape(transformed_expr)),
        unquote(deps)
      }
    end
  end

  @doc """
  Defines an optimistic action that runs on both server and client.

  This macro captures the source code of the `run` and `validate` functions
  for JavaScript compilation, then stores the action in a module attribute.

  ## Options

  - `:run` - Required. Function `fn current, value -> new_value end` that transforms the field
  - `:validate` - Optional. Function `fn current, value -> boolean end` for validation
  - `:max` - Optional. Field name containing max length for array fields

  ## Example

      optimistic_action :add, :tags,
        run: fn tags, tag -> tags ++ [tag] end,
        validate: fn tags, tag -> tag not in tags end,
        max: :max_tags

      optimistic_action :remove, :tags,
        run: fn tags, tag -> Enum.reject(tags, &(&1 == tag)) end
  """
  defmacro optimistic_action(name, field, opts) do
    # Extract run and validate from opts and convert to source strings
    run_expr = Keyword.get(opts, :run)
    validate_expr = Keyword.get(opts, :validate)

    run_source = if run_expr, do: Macro.to_string(run_expr), else: nil
    validate_source = if validate_expr, do: Macro.to_string(validate_expr), else: nil

    max_field = Keyword.get(opts, :max)

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

  # Extract dependency names from @var references in an expression
  defp extract_deps(expr) do
    expr
    |> find_at_refs([])
    |> Enum.uniq()
    |> Enum.map(&to_string/1)
  end

  defp find_at_refs({:@, _, [{var_name, _, _}]}, acc) when is_atom(var_name) do
    [var_name | acc]
  end

  defp find_at_refs({_form, _meta, args}, acc) when is_list(args) do
    Enum.reduce(args, acc, &find_at_refs/2)
  end

  defp find_at_refs({left, right}, acc) do
    acc = find_at_refs(left, acc)
    find_at_refs(right, acc)
  end

  defp find_at_refs(list, acc) when is_list(list) do
    Enum.reduce(list, acc, &find_at_refs/2)
  end

  defp find_at_refs(_other, acc), do: acc
end
