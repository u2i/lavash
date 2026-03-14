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

  alias Lavash.Optimistic.{ActionJs, StateJs}
  alias Lavash.Form.ValidationJs

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
    multi_select_action_fns = Enum.map(multi_selects, &StateJs.generate_multi_select_action_js/1)
    multi_select_derive_fns = Enum.map(multi_selects, &StateJs.generate_multi_select_derive_js/1)

    # Generate JS for toggle actions and derives
    toggle_action_fns = Enum.map(toggles, &StateJs.generate_toggle_action_js/1)
    toggle_derive_fns = Enum.map(toggles, &StateJs.generate_toggle_derive_js/1)

    # Generate JS for calculate macro derives
    calculation_fns = Enum.map(calculations, &generate_calculation_js/1) |> Enum.filter(& &1)

    # Generate JS for form validation derives (both _valid and _errors)
    form_validation_fns = Enum.map(form_validations, &generate_form_validation_js_entry/1)
    form_error_fns = Enum.map(form_errors, &generate_form_errors_js_entry/1)

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
    form_validation_derive_names = Enum.map(form_validations, fn {name, _, _, _} -> to_string(name) end)
    # form_errors tuples have 6 elements: {name, params_field, validation, custom_errors, ash_validations, skip_constraints}
    form_error_derive_names = Enum.map(form_errors, fn {name, _, _, _, _, _} -> to_string(name) end)
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
        normalized_deps = Enum.map(deps, &ActionJs.normalize_dep_to_string/1) |> Enum.uniq()
        {to_string(name), %{deps: normalized_deps}}
      end)

    # Form validation derives depend on their params field
    # Combined form validation derives depend on individual field validations
    form_validation_entries =
      Enum.map(form_validations, fn
        {name, _params_field, {:combined, form_name, field_names}, _skip} ->
          # Combined validation depends on individual field validations
          deps = Enum.map(field_names, fn field -> "#{form_name}_#{field}_valid" end)
          {to_string(name), %{deps: deps}}

        {name, params_field, _validation, _skip} ->
          # Individual field validation depends on params
          {to_string(name), %{deps: [to_string(params_field)]}}
      end)

    # Form error derives depend on params field (same as validations)
    # 6-tuple format: {name, params_field, validation, custom_errors, ash_validations, skip_constraints}
    form_error_entries =
      Enum.map(form_errors, fn
        {name, _params_field, {:combined, form_name, field_names}, _custom_errors, _ash_validations, _skip} ->
          # Combined errors depends on individual field errors
          deps = Enum.map(field_names, fn field -> "#{form_name}_#{field}_errors" end)
          {to_string(name), %{deps: deps}}

        {name, params_field, _validation, _custom_errors, _ash_validations, _skip} ->
          # Individual field errors depends on params
          {to_string(name), %{deps: [to_string(params_field)]}}
      end)

    (explicit_entries ++ multi_select_entries ++ toggle_entries ++ calculation_entries ++ form_validation_entries ++ form_error_entries)
    |> Map.new()
  end

  # Dependency normalization delegated to ActionJs

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

  defp action_is_optimistic?(action), do: ActionJs.action_is_optimistic?(action)

  defp generate_action_js(action) do
    name = action.name
    sets = action.sets || []
    updates = action.updates || []
    runs = action.runs || []
    params = action.params || []
    reads = action.reads || []

    # Check if we can generate this action
    # We can only generate actions where values/fns are simple transformations
    set_exprs = Enum.map(sets, &generate_set_js/1)
    update_exprs = Enum.map(updates, &generate_update_js/1)

    # Handle runs - they may return statements + return object pairs
    # Pass action-level reads to determine if transpilation is possible
    run_results = Enum.map(runs, &generate_run_js(&1, reads))

    # Check if any run returned nil (not transpilable) or all sets/updates are nil
    all_simple_exprs = set_exprs ++ update_exprs
    run_failed = Enum.any?(run_results, fn
      {:ok, _statements, _return_parts} -> false
      nil -> true
    end)

    if Enum.any?(all_simple_exprs, &is_nil/1) or run_failed do
      nil
    else
      # Collect all JS statements from runs
      all_statements = Enum.flat_map(run_results, fn
        {:ok, statements, _return_parts} -> statements
        _ -> []
      end)

      # Collect all return parts from runs
      run_return_parts = Enum.flat_map(run_results, fn
        {:ok, _statements, return_parts} -> return_parts
        _ -> []
      end)

      # Combine all return expressions
      all_return_exprs = all_simple_exprs ++ run_return_parts
      expr_pairs = Enum.join(all_return_exprs, ", ")

      # Include value param if action has params
      param_str = if params != [], do: ", value", else: ""

      if all_statements == [] do
        # Simple case: just return object
        """
          #{name}(state#{param_str}) {
            return { #{expr_pairs} };
          }
        """
      else
        # Complex case: statements before return
        statements_str = Enum.join(all_statements, "\n    ")
        """
          #{name}(state#{param_str}) {
            #{statements_str}
            return { #{expr_pairs} };
          }
        """
      end
    end
  end

  # Generate JS for a run operation
  # Transpilable when action has reads declared
  # Returns {:ok, statements, return_parts} or nil
  defp generate_run_js(run, action_reads) do
    if action_reads != [] do
      # Extract function body from AST: {:fn, _, [{:->, _, [[_arg], body]}]}
      case run.fun do
        {:fn, _, [{:->, _, [[_arg], body]}]} ->
          # Use the transpiler to convert the body to JS
          case transpile_run_body_to_js(body) do
            {:ok, js_statements, return_obj} ->
              # Parse the return object to extract individual field assignments
              # return_obj is like "{count: 0, multiplier: 2}"
              # We need to extract the inner parts: "count: 0, multiplier: 2"
              return_parts = parse_return_object(return_obj)
              {:ok, js_statements, return_parts}

            {:error, _reason} ->
              nil
          end

        _ ->
          # Unexpected AST format
          nil
      end
    else
      # Action without reads - runs cannot be transpiled
      nil
    end
  end

  # Parse a JS return object like "{count: 0, multiplier: 2}" into parts
  defp parse_return_object(return_obj) do
    # Remove surrounding braces and split into individual assignments
    inner = return_obj
            |> String.trim()
            |> String.trim_leading("{")
            |> String.trim_trailing("}")
            |> String.trim()

    if inner == "" do
      []
    else
      [inner]
    end
  end

  # Transpile a run function body to JS statements and return expression
  defp transpile_run_body_to_js(body) do
    try do
      {statements, return_obj} = Lavash.Rx.Transpiler.transpile_run_body(body)
      {:ok, statements, return_obj}
    rescue
      _ -> {:error, :transpilation_failed}
    end
  end

  defp generate_set_js(set) do
    field = set.field

    case ActionJs.analyze_value(set.value) do
      {:rx, source} ->
        js_expr = Lavash.Rx.Transpiler.to_js(source)
        "#{field}: #{js_expr}"

      {:literal, v} ->
        "#{field}: #{Jason.encode!(v)}"

      :from_params_value ->
        "#{field}: Number(value)"

      :unknown ->
        nil
    end
  end

  defp generate_update_js(update), do: ActionJs.generate_update_js(update)

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
    js_expr = Lavash.Rx.Transpiler.to_js(source)

    """
      #{name}(state) {
        return #{js_expr};
      }
    """
  end

  # Normalize calculation tuple to consistent format
  defp normalize_calculation({name, source, ast, deps}), do: {name, source, ast, deps}
  defp normalize_calculation({name, source, ast, deps, _opt, _async, _reads}), do: {name, source, ast, deps}

  # Multi-select and toggle JS generation delegated to StateJs

  # ============================================
  # Form validation support
  # ============================================

  # Get form validations from module's forms and Ash resource constraints
  # Returns list of {derive_name, params_field, validation, skip_constraints} tuples
  defp get_form_validations(module) do
    try do
      forms = module.__lavash__(:forms)

      Enum.flat_map(forms, fn form ->
        resource = form.resource
        form_name = form.name
        params_field = :"#{form_name}_params"
        skip_constraints = form.skip_constraints || []

        if Code.ensure_loaded?(resource) and
             function_exported?(resource, :spark_dsl_config, 0) do
          validations = Lavash.Form.ConstraintTranspiler.extract_validations(resource)

          # Filter out skipped fields and generate per-field validation derives
          non_skipped_validations = Enum.reject(validations, fn v -> v.field in skip_constraints end)

          field_derives =
            Enum.map(non_skipped_validations, fn validation ->
              derive_name = :"#{form_name}_#{validation.field}_valid"
              {derive_name, params_field, validation, false}
            end)

          # Generate overall form_valid derive if we have field validations (excluding skipped)
          if length(non_skipped_validations) > 0 do
            field_names = Enum.map(non_skipped_validations, & &1.field)
            form_valid = {:"#{form_name}_valid", params_field, {:combined, form_name, field_names}, false}
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
  # Returns list of {derive_name, params_field, validation, custom_errors, ash_validations, skip_constraints} tuples for _errors fields
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
        skip_constraints = form.skip_constraints || []

        if Code.ensure_loaded?(resource) and
             function_exported?(resource, :spark_dsl_config, 0) do
          validations = Lavash.Form.ConstraintTranspiler.extract_validations(resource)

          # Filter out skipped fields
          non_skipped_validations = Enum.reject(validations, fn v -> v.field in skip_constraints end)

          # Also get Ash validations with custom messages
          ash_validations = Lavash.Form.ValidationTranspiler.extract_validations_for_action(resource, create_action)

          # Generate per-field error derives with custom errors and ash validations (excluding skipped)
          field_derives =
            Enum.map(non_skipped_validations, fn validation ->
              derive_name = :"#{form_name}_#{validation.field}_errors"
              custom_errors = Map.get(extend_errors_map, derive_name, [])
              field_ash_validations = Map.get(ash_validations, validation.field, [])
              {derive_name, params_field, validation, custom_errors, field_ash_validations, false}
            end)

          # Generate overall form_errors derive if we have field validations (excluding skipped)
          if length(non_skipped_validations) > 0 do
            field_names = Enum.map(non_skipped_validations, & &1.field)
            form_errors = {:"#{form_name}_errors", params_field, {:combined, form_name, field_names}, [], [], false}
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

  # Form validation/error JS - delegate to ValidationJs

  defp generate_form_validation_js_entry({name, _params_field, {:combined, form_name, field_names}, _skip}) do
    ValidationJs.generate_combined_validation_js(name, form_name, field_names)
  end

  defp generate_form_validation_js_entry({name, params_field, validation, skip_constraints}) do
    ValidationJs.generate_field_validation_js(name, params_field, validation, skip_constraints)
  end

  defp generate_form_errors_js_entry({name, _params_field, {:combined, form_name, field_names}, _custom_errors, _ash_validations, _skip}) do
    ValidationJs.generate_combined_errors_js(name, form_name, field_names)
  end

  defp generate_form_errors_js_entry({name, params_field, validation, custom_errors, ash_validations, skip_constraints}) do
    ValidationJs.generate_field_errors_js(name, params_field, validation, custom_errors, ash_validations, skip_constraints)
  end
end
