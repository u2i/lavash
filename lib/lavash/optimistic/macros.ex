defmodule Lavash.Optimistic.Macros do
  @moduledoc """
  Macros for optimistic actions.

  The `optimistic_action` macro captures source code at compile time for
  transpilation to JavaScript, enabling client-side optimistic updates.

  Note: The `calculate` macro has been deprecated in favor of the Spark DSL:
  `calculate :name, rx(expr)` - see `Lavash.Dsl` for documentation.
  """

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
end
