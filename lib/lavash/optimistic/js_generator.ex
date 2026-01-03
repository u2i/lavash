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
    form_validations = get_form_validations(module)
    form_errors = get_form_errors(module)

    action_fns = Enum.map(actions, &generate_action_js/1) |> Enum.filter(& &1)

    # Generate JS for multi_select actions and derives
    multi_select_action_fns = Enum.map(multi_selects, &generate_multi_select_action_js/1)
    multi_select_derive_fns = Enum.map(multi_selects, &generate_multi_select_derive_js/1)

    # Generate JS for toggle actions and derives
    toggle_action_fns = Enum.map(toggles, &generate_toggle_action_js/1)
    toggle_derive_fns = Enum.map(toggles, &generate_toggle_derive_js/1)

    # Generate JS for calculate macro derives
    calculation_fns = Enum.map(calculations, &generate_calculation_js/1) |> Enum.filter(& &1)

    # Generate JS for form validation derives (both _valid and _errors)
    form_validation_fns = Enum.map(form_validations, &generate_form_validation_js/1)
    form_error_fns = Enum.map(form_errors, &generate_form_errors_js/1)

    # Build the JS object
    fns = action_fns ++ multi_select_action_fns ++ multi_select_derive_fns ++ toggle_action_fns ++ toggle_derive_fns ++ calculation_fns ++ form_validation_fns ++ form_error_fns

    # Add derives metadata for the hook (includes explicit and auto-generated)
    explicit_derive_names = Enum.map(derives, & &1.name) |> Enum.map(&to_string/1)
    multi_select_derive_names = Enum.map(multi_selects, fn ms -> "#{ms.name}_chips" end)
    toggle_derive_names = Enum.map(toggles, fn t -> "#{t.name}_chip" end)
    calculation_derive_names = Enum.map(calculations, fn calc ->
      {name, _, _, _} = normalize_calculation(calc)
      to_string(name)
    end)
    form_validation_derive_names = Enum.map(form_validations, fn {name, _, _} -> to_string(name) end)
    # form_errors tuples have 5 elements: {name, params_field, validation, custom_errors, ash_validations}
    form_error_derive_names = Enum.map(form_errors, fn {name, _, _, _, _} -> to_string(name) end)
    derive_names = explicit_derive_names ++ multi_select_derive_names ++ toggle_derive_names ++ calculation_derive_names ++ form_validation_derive_names ++ form_error_derive_names

    # Add optimistic field names
    field_names = Enum.map(optimistic_fields, & &1.name) |> Enum.map(&to_string/1)

    # Build graph metadata for each derive
    # Format: { name: { deps: [...], fn: function }, ... }
    graph_entries = build_graph_entries(derives, multi_selects, toggles, calculations, form_validations, form_errors)

    if fns == [] and derive_names == [] do
      nil
    else
      fns_str = Enum.join(fns, ",\n")
      derives_str = Jason.encode!(derive_names)
      fields_str = Jason.encode!(field_names)
      graph_str = Jason.encode!(graph_entries)

      # Generate ES module format for colocated JS extraction
      """
      export default {
      #{fns_str}#{if fns_str != "", do: ",", else: ""}
      __derives__: #{derives_str},
      __fields__: #{fields_str},
      __graph__: #{graph_str}
      };
      """
    end
  end

  # Build graph entries with dependency information for each derive
  defp build_graph_entries(derives, multi_selects, toggles, calculations, form_validations, form_errors) do
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
    # Deps can be atoms (:count) or path tuples ({:path, :params, ["name"]})
    calculation_entries =
      Enum.map(calculations, fn calc ->
        {name, _source, _ast, deps} = normalize_calculation(calc)
        # Normalize deps to string field names
        normalized_deps = Enum.map(deps, &normalize_dep_to_string/1) |> Enum.uniq()
        {to_string(name), %{deps: normalized_deps}}
      end)

    # Form validation derives depend on their params field
    # Combined form validation derives depend on individual field validations
    form_validation_entries =
      Enum.map(form_validations, fn
        {name, _params_field, {:combined, form_name, field_names}} ->
          # Combined validation depends on individual field validations
          deps = Enum.map(field_names, fn field -> "#{form_name}_#{field}_valid" end)
          {to_string(name), %{deps: deps}}

        {name, params_field, _validation} ->
          # Individual field validation depends on params
          {to_string(name), %{deps: [to_string(params_field)]}}
      end)

    # Form error derives depend on params field (same as validations)
    # 5-tuple format: {name, params_field, validation, custom_errors, ash_validations}
    form_error_entries =
      Enum.map(form_errors, fn
        {name, _params_field, {:combined, form_name, field_names}, _custom_errors, _ash_validations} ->
          # Combined errors depends on individual field errors
          deps = Enum.map(field_names, fn field -> "#{form_name}_#{field}_errors" end)
          {to_string(name), %{deps: deps}}

        {name, params_field, _validation, _custom_errors, _ash_validations} ->
          # Individual field errors depends on params
          {to_string(name), %{deps: [to_string(params_field)]}}
      end)

    (explicit_entries ++ multi_select_entries ++ toggle_entries ++ calculation_entries ++ form_validation_entries ++ form_error_entries)
    |> Map.new()
  end

  # Normalize a dependency to its root field name as a string
  # Path deps like {:path, :params, ["name"]} -> "params"
  # Atom deps like :count -> "count"
  defp normalize_dep_to_string({:path, root, _path}), do: to_string(root)
  defp normalize_dep_to_string(atom) when is_atom(atom), do: to_string(atom)

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

  # Get calculations from __lavash_calculations__/0 function
  # Returns list of tuples in either 4-tuple or 7-tuple format
  defp get_calculations(module) do
    if function_exported?(module, :__lavash_calculations__, 0) do
      module.__lavash_calculations__()
    else
      []
    end
  end

  # Generate JS for a calculation (transpile Elixir expression to JS)
  # Handles both 4-tuple and 7-tuple formats
  defp generate_calculation_js(calc) do
    {name, source, _ast, _deps} = normalize_calculation(calc)

    # Use the existing elixir_to_js transpiler
    js_expr = Lavash.Template.elixir_to_js(source)

    """
      #{name}(state) {
        return #{js_expr};
      }
    """
  end

  # Normalize calculation tuple to consistent format
  defp normalize_calculation({name, source, ast, deps}), do: {name, source, ast, deps}
  defp normalize_calculation({name, source, ast, deps, _opt, _async, _reads}), do: {name, source, ast, deps}

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

  # ============================================
  # Form validation support
  # ============================================

  # Get form validations from module's forms and Ash resource constraints
  # Returns list of {derive_name, params_field, validation} tuples
  defp get_form_validations(module) do
    try do
      forms = module.__lavash__(:forms)

      Enum.flat_map(forms, fn form ->
        resource = form.resource
        form_name = form.name
        params_field = :"#{form_name}_params"

        if Code.ensure_loaded?(resource) and
             function_exported?(resource, :spark_dsl_config, 0) do
          validations = Lavash.Form.ConstraintTranspiler.extract_validations(resource)

          # Generate per-field validation derives
          field_derives =
            Enum.map(validations, fn validation ->
              derive_name = :"#{form_name}_#{validation.field}_valid"
              {derive_name, params_field, validation}
            end)

          # Generate overall form_valid derive if we have field validations
          if length(validations) > 0 do
            field_names = Enum.map(validations, & &1.field)
            form_valid = {:"#{form_name}_valid", params_field, {:combined, form_name, field_names}}
            field_derives ++ [form_valid]
          else
            field_derives
          end
        else
          []
        end
      end)
    rescue
      _ -> []
    end
  end

  # Get form error derives from module's forms
  # Returns list of {derive_name, params_field, validation, custom_errors, ash_validations} tuples for _errors fields
  defp get_form_errors(module) do
    try do
      forms = module.__lavash__(:forms)

      # Get extend_errors declarations as a map
      extend_errors_map = get_extend_errors_map(module)

      Enum.flat_map(forms, fn form ->
        resource = form.resource
        form_name = form.name
        params_field = :"#{form_name}_params"
        create_action = form.create || :create

        if Code.ensure_loaded?(resource) and
             function_exported?(resource, :spark_dsl_config, 0) do
          validations = Lavash.Form.ConstraintTranspiler.extract_validations(resource)

          # Also get Ash validations with custom messages
          ash_validations = Lavash.Form.ValidationTranspiler.extract_validations_for_action(resource, create_action)

          # Generate per-field error derives with custom errors and ash validations
          field_derives =
            Enum.map(validations, fn validation ->
              derive_name = :"#{form_name}_#{validation.field}_errors"
              custom_errors = Map.get(extend_errors_map, derive_name, [])
              field_ash_validations = Map.get(ash_validations, validation.field, [])
              {derive_name, params_field, validation, custom_errors, field_ash_validations}
            end)

          # Generate overall form_errors derive if we have field validations
          if length(validations) > 0 do
            field_names = Enum.map(validations, & &1.field)
            form_errors = {:"#{form_name}_errors", params_field, {:combined, form_name, field_names}, [], []}
            field_derives ++ [form_errors]
          else
            field_derives
          end
        else
          []
        end
      end)
    rescue
      _ -> []
    end
  end

  # Get extend_errors declarations as a map from field name to list of errors
  defp get_extend_errors_map(module) do
    try do
      if function_exported?(module, :__lavash__, 1) do
        module.__lavash__(:extend_errors)
        |> Enum.map(fn ext -> {ext.field, ext.errors} end)
        |> Map.new()
      else
        %{}
      end
    rescue
      _ -> %{}
    end
  end

  # Generate JS for a form field validation derive
  defp generate_form_validation_js({name, _params_field, {:combined, form_name, field_names}}) do
    # Combined form validity - AND all individual field validations
    checks =
      field_names
      |> Enum.map(fn field -> "state.#{form_name}_#{field}_valid" end)
      |> Enum.join(" && ")

    """
      #{name}(state) {
        return #{checks};
      }
    """
  end

  defp generate_form_validation_js({name, params_field, validation}) do
    field = validation.field
    field_str = to_string(field)
    required = validation.required
    type = validation.type
    constraints = validation.constraints

    # Build JS validation expression
    value_expr = "state.#{params_field}?.[#{Jason.encode!(field_str)}]"

    checks = []

    # Required check: not null/undefined and not empty after trim
    checks =
      if required do
        check = "(#{value_expr} != null && String(#{value_expr}).trim().length > 0)"
        [check | checks]
      else
        checks
      end

    # Type-specific constraint checks
    checks =
      case type do
        :string ->
          build_string_constraint_checks(value_expr, constraints, checks)

        :integer ->
          build_integer_constraint_checks(value_expr, constraints, checks)

        _ ->
          checks
      end

    # Combine all checks with &&
    expr =
      case checks do
        [] -> "true"
        [single] -> single
        multiple -> Enum.join(Enum.reverse(multiple), " && ")
      end

    """
      #{name}(state) {
        return #{expr};
      }
    """
  end

  defp build_string_constraint_checks(value_expr, constraints, checks) do
    checks =
      case Map.get(constraints, :min_length) do
        nil -> checks
        min -> ["(String(#{value_expr} || '').trim().length >= #{min})" | checks]
      end

    checks =
      case Map.get(constraints, :max_length) do
        nil -> checks
        max -> ["(String(#{value_expr} || '').trim().length <= #{max})" | checks]
      end

    checks =
      case Map.get(constraints, :match) do
        nil ->
          checks

        regex ->
          # Convert Elixir regex to JS regex pattern
          pattern = Regex.source(regex)
          ["(#{Jason.encode!(pattern)}).match(#{value_expr} || '')" | checks]
      end

    checks
  end

  defp build_integer_constraint_checks(value_expr, constraints, checks) do
    parsed = "parseInt(#{value_expr} || '0', 10)"

    checks =
      case Map.get(constraints, :min) do
        nil -> checks
        min -> ["(#{parsed} >= #{min})" | checks]
      end

    checks =
      case Map.get(constraints, :max) do
        nil -> checks
        max -> ["(#{parsed} <= #{max})" | checks]
      end

    checks
  end

  # Generate JS for form field error derives
  defp generate_form_errors_js({name, _params_field, {:combined, form_name, field_names}, _custom_errors, _ash_validations}) do
    # Combined errors - concatenate all individual field error arrays
    arrays =
      field_names
      |> Enum.map(fn field -> "...(state.#{form_name}_#{field}_errors || [])" end)
      |> Enum.join(", ")

    """
      #{name}(state) {
        return [#{arrays}];
      }
    """
  end

  defp generate_form_errors_js({name, params_field, validation, custom_errors, ash_validations}) do
    field = validation.field
    field_str = to_string(field)
    required = validation.required
    type = validation.type
    constraints = validation.constraints

    value_expr = "state.#{params_field}?.[#{Jason.encode!(field_str)}]"

    # Build a lookup of custom messages from Ash validations
    # %{:required => "Enter a card number", :min_length => "Card number too short", ...}
    ash_messages = build_ash_message_lookup(ash_validations)

    # Build error checks - each returns error message if check fails
    error_checks = []

    # Required check
    error_checks =
      if required do
        msg = Map.get(ash_messages, :required) || Lavash.Form.ConstraintTranspiler.error_message(:required, nil)
        check = "{check: #{value_expr} != null && String(#{value_expr}).trim().length > 0, msg: #{Jason.encode!(msg)}}"
        [check | error_checks]
      else
        error_checks
      end

    # Type-specific constraint checks
    error_checks =
      case type do
        :string ->
          build_string_error_checks(value_expr, constraints, error_checks, ash_messages)

        :integer ->
          build_integer_error_checks(value_expr, constraints, error_checks, ash_messages)

        _ ->
          error_checks
      end

    # Add custom error checks from extend_errors
    # These use rx() expressions that are transpiled to JS
    # Messages can be static strings or dynamic rx() expressions
    error_checks =
      Enum.reduce(custom_errors, error_checks, fn error, acc ->
        # Transpile the rx condition to JS - condition returns true when error should show
        js_condition = Lavash.Template.elixir_to_js(error.condition.source)

        # Handle both static string messages and dynamic rx() messages
        msg_js = case error.message do
          %Lavash.Rx{source: source} ->
            # Dynamic message - transpile the expression
            "(#{Lavash.Template.elixir_to_js(source)})"
          static_string when is_binary(static_string) ->
            # Static message - JSON encode
            Jason.encode!(static_string)
        end

        # Note: for custom errors, check is true when the field is VALID, so we negate the condition
        check = "{check: !(#{js_condition}), msg: #{msg_js}}"
        [check | acc]
      end)

    checks_array = "[" <> Enum.join(Enum.reverse(error_checks), ", ") <> "]"

    # JS function that returns array of error messages for failed checks
    # Only check constraints if field is not empty (unless required)
    """
      #{name}(state) {
        const v = #{value_expr};
        const isEmpty = v == null || String(v).trim().length === 0;
        const checks = #{checks_array};
        return checks
          .filter(c => !c.check && (#{required} || !isEmpty))
          .map(c => c.msg);
      }
    """
  end

  defp build_string_error_checks(value_expr, constraints, checks, ash_messages) do
    checks =
      case Map.get(constraints, :min_length) do
        nil ->
          checks

        min ->
          # Look for min_length or length_between message from Ash validations
          msg = Map.get(ash_messages, :min_length) ||
                Map.get(ash_messages, :length_between) ||
                Lavash.Form.ConstraintTranspiler.error_message(:min_length, min)
          check = "{check: String(#{value_expr} || '').trim().length >= #{min}, msg: #{Jason.encode!(msg)}}"
          [check | checks]
      end

    checks =
      case Map.get(constraints, :max_length) do
        nil ->
          checks

        max ->
          # Look for max_length or length_between message from Ash validations
          msg = Map.get(ash_messages, :max_length) ||
                Map.get(ash_messages, :length_between) ||
                Lavash.Form.ConstraintTranspiler.error_message(:max_length, max)
          check = "{check: String(#{value_expr} || '').trim().length <= #{max}, msg: #{Jason.encode!(msg)}}"
          [check | checks]
      end

    checks =
      case Map.get(constraints, :match) do
        nil ->
          checks

        regex ->
          pattern = Regex.source(regex)
          msg = Map.get(ash_messages, :match) ||
                Lavash.Form.ConstraintTranspiler.error_message(:match, regex)
          check = "{check: new RegExp(#{Jason.encode!(pattern)}).test(#{value_expr} || ''), msg: #{Jason.encode!(msg)}}"
          [check | checks]
      end

    checks
  end

  defp build_integer_error_checks(value_expr, constraints, checks, ash_messages) do
    parsed = "parseInt(#{value_expr} || '0', 10)"

    checks =
      case Map.get(constraints, :min) do
        nil ->
          checks

        min ->
          msg = Map.get(ash_messages, :min) ||
                Map.get(ash_messages, :numericality) ||
                Lavash.Form.ConstraintTranspiler.error_message(:min, min)
          check = "{check: #{parsed} >= #{min}, msg: #{Jason.encode!(msg)}}"
          [check | checks]
      end

    checks =
      case Map.get(constraints, :max) do
        nil ->
          checks

        max ->
          msg = Map.get(ash_messages, :max) ||
                Map.get(ash_messages, :numericality) ||
                Lavash.Form.ConstraintTranspiler.error_message(:max, max)
          check = "{check: #{parsed} <= #{max}, msg: #{Jason.encode!(msg)}}"
          [check | checks]
      end

    checks
  end

  # Build a lookup map from ash_validations list to their messages
  # e.g. [%{type: :required, message: "Enter a card number"}, ...]
  # => %{:required => "Enter a card number", ...}
  defp build_ash_message_lookup(ash_validations) do
    Enum.reduce(ash_validations, %{}, fn spec, acc ->
      if spec.message do
        # Get the resolved message using ValidationTranspiler
        message = Lavash.Form.ValidationTranspiler.get_message(spec)
        Map.put(acc, spec.type, message)
      else
        acc
      end
    end)
  end
end
