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
    multi_selects = get_multi_selects(module)
    toggles = get_toggles(module)
    calculations = get_calculations(module)

    action_fns = Enum.map(actions, &generate_action_js/1) |> Enum.filter(& &1)

    # Generate JS for multi_select actions and derives
    multi_select_action_fns = Enum.map(multi_selects, &generate_multi_select_action_js/1)
    multi_select_derive_fns = Enum.map(multi_selects, &generate_multi_select_derive_js/1)

    # Generate JS for toggle actions and derives
    toggle_action_fns = Enum.map(toggles, &generate_toggle_action_js/1)
    toggle_derive_fns = Enum.map(toggles, &generate_toggle_derive_js/1)

    # Generate JS for calculate macro derives
    calculation_fns = Enum.map(calculations, &generate_calculation_js/1) |> Enum.filter(& &1)

    # Build the JS object
    fns = action_fns ++ multi_select_action_fns ++ multi_select_derive_fns ++ toggle_action_fns ++ toggle_derive_fns ++ calculation_fns

    # Add derives metadata for the hook (includes explicit and auto-generated)
    explicit_derive_names = Enum.map(derives, & &1.name) |> Enum.map(&to_string/1)
    multi_select_derive_names = Enum.map(multi_selects, fn ms -> "#{ms.name}_chips" end)
    toggle_derive_names = Enum.map(toggles, fn t -> "#{t.name}_chip" end)
    calculation_derive_names = Enum.map(calculations, fn {name, _, _, _} -> to_string(name) end)
    derive_names = explicit_derive_names ++ multi_select_derive_names ++ toggle_derive_names ++ calculation_derive_names

    # Add optimistic field names
    field_names = Enum.map(optimistic_fields, & &1.name) |> Enum.map(&to_string/1)

    # Build graph metadata for each derive
    # Format: { name: { deps: [...], fn: function }, ... }
    graph_entries = build_graph_entries(derives, multi_selects, toggles, calculations)

    if fns == [] and derive_names == [] do
      nil
    else
      fns_str = Enum.join(fns, ",\n")
      derives_str = Jason.encode!(derive_names)
      fields_str = Jason.encode!(field_names)
      graph_str = Jason.encode!(graph_entries)

      """
      {
      #{fns_str}#{if fns_str != "", do: ",", else: ""}
      __derives__: #{derives_str},
      __fields__: #{fields_str},
      __graph__: #{graph_str}
      }
      """
    end
  end

  # Build graph entries with dependency information for each derive
  defp build_graph_entries(derives, multi_selects, toggles, calculations) do
    # Explicit derives from DSL
    explicit_entries =
      Enum.map(derives, fn derive ->
        # Extract deps from arguments (raw DSL entity doesn't have depends_on populated)
        deps = extract_deps_from_arguments(derive.arguments || [])
        {to_string(derive.name), %{deps: deps}}
      end)

    # Multi-select derives depend on their field
    multi_select_entries =
      Enum.map(multi_selects, fn ms ->
        {"#{ms.name}_chips", %{deps: [to_string(ms.name)]}}
      end)

    # Toggle derives depend on their field
    toggle_entries =
      Enum.map(toggles, fn t ->
        {"#{t.name}_chip", %{deps: [to_string(t.name)]}}
      end)

    # Calculation derives have deps extracted from @var references
    calculation_entries =
      Enum.map(calculations, fn {name, _source, _ast, deps} ->
        {to_string(name), %{deps: deps}}
      end)

    (explicit_entries ++ multi_select_entries ++ toggle_entries ++ calculation_entries)
    |> Map.new()
  end

  # Extract dependency names from argument list
  defp extract_deps_from_arguments(arguments) do
    Enum.map(arguments, fn arg ->
      source = arg.source || {:state, arg.name}
      case source do
        {:state, name} -> to_string(name)
        {:result, name} -> to_string(name)
        {:prop, name} -> to_string(name)
        name when is_atom(name) -> to_string(name)
        _ -> nil
      end
    end)
    |> Enum.filter(& &1)
  end

  defp get_optimistic_actions(module) do
    try do
      # Get names of multi_select and toggle actions (handled separately)
      multi_select_names = module.__lavash__(:multi_selects) |> Enum.map(& &1.name)
      toggle_names = module.__lavash__(:toggles) |> Enum.map(& &1.name)

      # Exclude toggle actions and setter actions for these fields
      excluded_names =
        (Enum.map(multi_select_names, &:"toggle_#{&1}") ++
         Enum.map(multi_select_names, &:"set_#{&1}") ++
         Enum.map(toggle_names, &:"toggle_#{&1}") ++
         Enum.map(toggle_names, &:"set_#{&1}"))
        |> MapSet.new()

      module.__lavash__(:actions)
      |> Enum.filter(&action_is_optimistic?/1)
      # Exclude actions already handled by multi_select/toggle
      |> Enum.reject(&MapSet.member?(excluded_names, &1.name))
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
    # We can only reliably detect simple patterns like & &1.params.value
    # by testing the function with a mock context
    try do
      # Test with a mock context that has params.value
      test_ctx = %{params: %{value: "__TEST_VALUE__"}, state: %{}}
      result = value.(test_ctx)

      # If the result is exactly our test value, it's a direct params accessor
      if result == "__TEST_VALUE__" do
        :from_params_value
      else
        :unknown
      end
    rescue
      _ -> :unknown
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

  # ============================================
  # Multi-select and Toggle support
  # ============================================

  defp get_multi_selects(module) do
    try do
      module.__lavash__(:multi_selects)
    rescue
      _ -> []
    end
  end

  defp get_toggles(module) do
    try do
      module.__lavash__(:toggles)
    rescue
      _ -> []
    end
  end

  # Get calculations from module attribute (set by calculate macro)
  defp get_calculations(module) do
    try do
      # Calculations are stored as tuples: {name, source, ast, deps}
      Module.get_attribute(module, :__lavash_calculations__) || []
    rescue
      _ ->
        # Module already compiled, try to get from __lavash_calculations__/0 function
        if function_exported?(module, :__lavash_calculations__, 0) do
          module.__lavash_calculations__()
        else
          []
        end
    end
  end

  # Generate JS for a calculation (transpile Elixir expression to JS)
  defp generate_calculation_js({name, source, _ast, _deps}) do
    # Use the existing elixir_to_js transpiler
    js_expr = Lavash.Template.elixir_to_js(source)

    """
      #{name}(state) {
        return #{js_expr};
      }
    """
  end

  @default_chip_class [
    base: "px-3 py-1.5 text-sm rounded-full border transition-colors cursor-pointer",
    active: "bg-primary text-primary-content border-primary",
    inactive: "bg-base-100 text-base-content/70 border-base-300 hover:border-primary/50"
  ]

  # Generate JS for multi_select toggle action
  defp generate_multi_select_action_js(%Lavash.MultiSelect{} = ms) do
    action_name = "toggle_#{ms.name}"
    field = ms.name

    """
      #{action_name}(state, value) {
        const list = state.#{field} || [];
        const idx = list.indexOf(value);
        if (idx >= 0) {
          return { #{field}: list.filter(v => v !== value) };
        } else {
          return { #{field}: [...list, value] };
        }
      }
    """
  end

  # Generate JS for multi_select chip derive
  defp generate_multi_select_derive_js(%Lavash.MultiSelect{} = ms) do
    derive_name = "#{ms.name}_chips"
    field = ms.name
    values = ms.values
    chip_class = ms.chip_class || @default_chip_class

    base = Keyword.get(chip_class, :base, "")
    active = Keyword.get(chip_class, :active, "")
    inactive = Keyword.get(chip_class, :inactive, "")

    active_class = String.trim("#{base} #{active}")
    inactive_class = String.trim("#{base} #{inactive}")

    values_json = Jason.encode!(values)

    """
      #{derive_name}(state) {
        const ACTIVE = #{Jason.encode!(active_class)};
        const INACTIVE = #{Jason.encode!(inactive_class)};
        const values = #{values_json};
        const selected = state.#{field} || [];
        const result = {};
        for (const v of values) {
          result[v] = selected.includes(v) ? ACTIVE : INACTIVE;
        }
        return result;
      }
    """
  end

  # Generate JS for toggle action
  defp generate_toggle_action_js(%Lavash.Toggle{} = toggle) do
    action_name = "toggle_#{toggle.name}"
    field = toggle.name

    """
      #{action_name}(state) {
        return { #{field}: !state.#{field} };
      }
    """
  end

  # Generate JS for toggle chip derive
  defp generate_toggle_derive_js(%Lavash.Toggle{} = toggle) do
    derive_name = "#{toggle.name}_chip"
    field = toggle.name
    chip_class = toggle.chip_class || @default_chip_class

    base = Keyword.get(chip_class, :base, "")
    active = Keyword.get(chip_class, :active, "")
    inactive = Keyword.get(chip_class, :inactive, "")

    active_class = String.trim("#{base} #{active}")
    inactive_class = String.trim("#{base} #{inactive}")

    """
      #{derive_name}(state) {
        const ACTIVE = #{Jason.encode!(active_class)};
        const INACTIVE = #{Jason.encode!(inactive_class)};
        return state.#{field} ? ACTIVE : INACTIVE;
      }
    """
  end
end
