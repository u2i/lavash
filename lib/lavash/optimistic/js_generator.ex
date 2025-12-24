defmodule Lavash.Optimistic.JsGenerator do
  @moduledoc """
  Generates JavaScript code for optimistic updates from Lavash DSL declarations.

  This module analyzes the DSL declarations and generates JS functions that mirror
  the server-side action logic, enabling instant client-side updates.

  ## What gets generated

  ### Actions
  For actions with `optimistic: true` that only use `set` and `update` operations:

  ```javascript
  // From: action :increment do update :count, &(&1 + 1) end
  increment(state) {
    return { count: state.count + 1 };
  }
  ```

  ### Derive metadata
  For derives with `optimistic: true`, metadata is included so the hook knows
  which functions are derives vs actions:

  ```javascript
  __derives__: ["doubled", "fact"]
  ```

  ## Usage

  The generated JS is automatically injected into the render output when using
  `Lavash.LiveView.Runtime.wrap_render/3`.
  """

  @doc """
  Generates JavaScript code for optimistic functions based on the module's DSL.

  Returns a JavaScript object literal string that can be used to register
  optimistic functions for the given module.
  """
  def generate(module) do
    actions = get_optimistic_actions(module)
    derives = get_optimistic_derives(module)
    optimistic_fields = get_optimistic_fields(module)

    action_fns = Enum.map(actions, &generate_action_js/1) |> Enum.filter(& &1)

    # Build the JS object
    fns = action_fns

    # Add derives metadata for the hook
    derive_names = Enum.map(derives, & &1.name) |> Enum.map(&to_string/1)

    # Add optimistic field names
    field_names = Enum.map(optimistic_fields, & &1.name) |> Enum.map(&to_string/1)

    if fns == [] and derive_names == [] do
      nil
    else
      fns_str = Enum.join(fns, ",\n")
      derives_str = Jason.encode!(derive_names)
      fields_str = Jason.encode!(field_names)

      """
      {
      #{fns_str}#{if fns_str != "", do: ",", else: ""}
      __derives__: #{derives_str},
      __fields__: #{fields_str}
      }
      """
    end
  end

  defp get_optimistic_actions(module) do
    try do
      module.__lavash__(:actions)
      |> Enum.filter(&action_is_optimistic?/1)
      # Deduplicate by name (keep first occurrence, which is the user-defined one)
      |> Enum.uniq_by(& &1.name)
    rescue
      _ -> []
    end
  end

  defp get_optimistic_derives(module) do
    try do
      module.__lavash__(:optimistic_derives)
    rescue
      _ -> []
    end
  end

  defp get_optimistic_fields(module) do
    try do
      module.__lavash__(:optimistic_fields)
    rescue
      _ -> []
    end
  end

  # An action is optimistic if:
  # 1. It has no side effects (no submits, navigates, effects, invokes)
  # 2. It only uses set/update on optimistic fields
  defp action_is_optimistic?(action) do
    has_side_effects =
      (action.submits || []) != [] or
      (action.navigates || []) != [] or
      (action.effects || []) != [] or
      (action.invokes || []) != []

    has_operations = (action.sets || []) != [] or (action.updates || []) != []

    !has_side_effects and has_operations
  end

  defp generate_action_js(action) do
    name = action.name
    sets = action.sets || []
    updates = action.updates || []
    params = action.params || []

    # Check if we can generate this action
    # We can only generate actions where values/fns are simple transformations
    set_exprs = Enum.map(sets, &generate_set_js/1)
    update_exprs = Enum.map(updates, &generate_update_js/1)

    all_exprs = set_exprs ++ update_exprs

    # If any expression is nil (not generatable), skip this action
    if Enum.any?(all_exprs, &is_nil/1) do
      nil
    else
      expr_pairs = Enum.join(all_exprs, ", ")

      # Include value param if action has params
      param_str = if params != [], do: ", value", else: ""

      """
        #{name}(state#{param_str}) {
          return { #{expr_pairs} };
        }
      """
    end
  end

  # Generate JS for a set operation
  # We can only generate JS for:
  # 1. Literal values: set :count, 0
  # 2. Functions that access params.value: set :count, &String.to_integer(&1.params.value)
  defp generate_set_js(set) do
    field = set.field
    value = set.value

    case analyze_value(value) do
      {:literal, v} ->
        "#{field}: #{Jason.encode!(v)}"

      :from_params_value ->
        # set :count, &String.to_integer(&1.params.value)
        # Assume the param is already the right type on client (from data-optimistic-value)
        "#{field}: Number(value)"

      :unknown ->
        nil
    end
  end

  # Generate JS for an update operation
  # We can only generate JS for simple numeric operations
  defp generate_update_js(update) do
    field = update.field
    fun = update.fun

    case analyze_update_function(fun) do
      {:increment, n} ->
        "#{field}: state.#{field} + #{n}"

      {:decrement, n} ->
        "#{field}: state.#{field} - #{n}"

      :unknown ->
        nil
    end
  end

  # Analyze a value to see if we can generate JS for it
  defp analyze_value(value) when is_number(value) or is_binary(value) or is_boolean(value) do
    {:literal, value}
  end

  defp analyze_value(value) when is_function(value, 1) do
    # Try to detect common patterns by inspecting the function
    # This is a heuristic - we look for &String.to_integer(&1.params.value) or similar
    info = Function.info(value)

    case info[:type] do
      :external ->
        # Check if it's the pattern: &String.to_integer(&1.params.value)
        # We can't introspect closures directly, but we know this is a common pattern
        # For now, assume any function that accesses params is :from_params_value
        :from_params_value

      _ ->
        :unknown
    end
  end

  defp analyze_value(_), do: :unknown

  # Analyze update functions to detect simple patterns
  defp analyze_update_function(fun) when is_function(fun, 1) do
    # Test the function with sample inputs to detect the pattern
    try do
      result_0 = fun.(0)
      result_10 = fun.(10)
      result_100 = fun.(100)

      # Check if there's a consistent delta
      delta1 = result_0 - 0
      delta2 = result_10 - 10
      delta3 = result_100 - 100

      if delta1 == delta2 and delta2 == delta3 do
        # All deltas are the same - this is a constant offset
        if delta1 >= 0 do
          {:increment, delta1}
        else
          {:decrement, -delta1}
        end
      else
        :unknown
      end
    rescue
      _ -> :unknown
    end
  end

  defp analyze_update_function(_), do: :unknown
end
