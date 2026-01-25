defmodule Lavash.Optimistic.ActionMacro do
  @moduledoc """
  Macro for defining optimistic actions that run on both client and server.

  This macro captures the source code of the `run` and `validate` functions
  for JavaScript compilation, then stores the action in a module attribute.

  Separated from Lavash.Optimistic.Macros to avoid conflicts with Spark DSL's
  `calculate` entity.
  """

  @doc """
  Defines an optimistic action that runs on both server and client.

  This macro captures the source code of the `run` and `validate` functions
  for JavaScript compilation, then stores the action in a module attribute.

  ## Options

  - `:run` - Required. Function `fn current, value -> new_value end` that transforms the field.
             For key-based actions, receives `fn item, value -> updated_item | :remove end`.
             Shorthands: `:remove` for removal actions, `:set` to directly set the value.
  - `:validate` - Optional. Function `fn current, value -> boolean end` for validation
  - `:key` - Optional. For array-of-objects: the field used to identify items (e.g., :id).
             When specified, the run function operates on the matched item instead of the array.
  - `:max` - Optional. Field name containing max length for array fields

  ## Example

      # Simple array of scalars
      optimistic_action :add, :tags,
        run: fn tags, tag -> tags ++ [tag] end,
        validate: fn tags, tag -> tag not in tags end,
        max: :max_tags

      optimistic_action :remove, :tags,
        run: fn tags, tag -> Enum.reject(tags, &(&1 == tag)) end

      # Array of objects with key-based identification
      optimistic_action :update_quantity, :items,
        key: :id,
        run: fn item, delta -> %{item | quantity: item.quantity + delta} end

      optimistic_action :remove_item, :items,
        key: :id,
        run: :remove  # Shorthand for removal
  """
  defmacro optimistic_action(name, field, opts) do
    # Extract options
    run_expr = Keyword.get(opts, :run)
    validate_expr = Keyword.get(opts, :validate)
    key_field = Keyword.get(opts, :key)
    max_field = Keyword.get(opts, :max)

    # Handle :remove and :set shorthands - store as string for JS detection
    run_source =
      case run_expr do
        :remove -> ":remove"
        :set -> ":set"
        expr when is_tuple(expr) -> Macro.to_string(expr)
        _ -> nil
      end

    validate_source = if validate_expr, do: Macro.to_string(validate_expr), else: nil

    quote do
      @__lavash_optimistic_actions__ {
        unquote(name),
        unquote(field),
        unquote(key_field),
        unquote(run_source),
        unquote(validate_source),
        unquote(max_field)
      }
    end
  end
end
