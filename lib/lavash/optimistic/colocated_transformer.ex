defmodule Lavash.Optimistic.ColocatedTransformer do
  @moduledoc """
  Spark transformer that extracts generated optimistic JS to colocated files.

  This runs at compile time and writes the generated JS functions to the
  phoenix-colocated directory, allowing them to be bundled by esbuild instead
  of being eval'd at runtime.

  The generated files integrate with Phoenix.LiveView.ColocatedJS system,
  which handles manifest generation and cleanup automatically.
  """

  use Spark.Dsl.Transformer

  alias Lavash.Component.CompilerHelpers

  # Run after all entities are defined but before compilation finishes
  def after?(_), do: true
  def before?(_), do: false

  @doc """
  Transform the DSL state by extracting optimistic JS to a colocated file.
  """
  def transform(dsl_state) do
    module = Spark.Dsl.Transformer.get_persisted(dsl_state, :module)
    env = Spark.Dsl.Transformer.get_persisted(dsl_state, :env)

    # Skip if module or env is not available (shouldn't happen)
    if is_nil(module) or is_nil(env) do
      {:ok, dsl_state}
    else
      extract_optimistic_js(dsl_state, module, env)
    end
  end

  defp extract_optimistic_js(dsl_state, module, env) do
    # Generate JS at compile time using the DSL state directly
    js_code = generate_js_from_dsl(dsl_state, module)

    if js_code do
      # Use Phoenix's colocated system via CompilerHelpers
      # This writes to the same directory as other colocated hooks
      colocated_data = write_colocated_optimistic(env, module, js_code)

      # Persist the colocated data so the compiler can include it in __phoenix_macro_components__
      dsl_state = Spark.Dsl.Transformer.persist(dsl_state, :lavash_optimistic_colocated_data, colocated_data)
      {:ok, dsl_state}
    else
      # No optimistic JS to generate - clean up any stale directory from previous compilations
      cleanup_stale_optimistic_dir(module)
      {:ok, dsl_state}
    end
  end

  # Remove stale optimistic directory when module no longer generates JS
  defp cleanup_stale_optimistic_dir(module) do
    target_dir = Lavash.Component.CompilerHelpers.get_target_dir()
    module_dir = Path.join(target_dir, inspect(module))

    if File.dir?(module_dir) do
      # Remove all optimistic_*.js files
      case File.ls(module_dir) do
        {:ok, files} ->
          for file <- files, String.starts_with?(file, "optimistic_") do
            File.rm(Path.join(module_dir, file))
          end

        _ ->
          :ok
      end

      # Remove directory if empty
      case File.ls(module_dir) do
        {:ok, []} -> File.rmdir(module_dir)
        _ -> :ok
      end
    end
  end

  # Write optimistic JS using Phoenix's colocated directory structure
  defp write_colocated_optimistic(env, module, js_code) do
    target_dir = CompilerHelpers.get_target_dir()
    module_dir = Path.join(target_dir, inspect(module))

    # Generate filename with hash for cache busting (same pattern as CompilerHelpers)
    hash = :crypto.hash(:md5, js_code) |> Base.encode32(case: :lower, padding: false)
    filename = "optimistic_#{hash}.js"
    full_path = Path.join(module_dir, filename)

    # Ensure directory exists
    File.mkdir_p!(module_dir)

    # Only write if content changed (avoids unnecessary esbuild rebuilds)
    needs_write =
      case File.read(full_path) do
        {:ok, existing} -> existing != js_code
        {:error, _} -> true
      end

    if needs_write do
      # Clean up old optimistic files in this module's directory
      case File.ls(module_dir) do
        {:ok, files} ->
          for file <- files, String.starts_with?(file, "optimistic_"), file != filename do
            File.rm(Path.join(module_dir, file))
          end

        _ ->
          :ok
      end

      # Write the new JS file
      File.write!(full_path, js_code)
    end

    # Return the data in the format Phoenix's ColocatedJS expects
    # Use key: "optimistic" to group all optimistic JS under a separate export
    # The name is the module name for lookup in the registry
    module_name = inspect(env.module)
    {filename, %{name: module_name, key: "optimistic"}}
  end

  defp generate_js_from_dsl(dsl_state, module) do
    # Get entities from DSL state
    alias Spark.Dsl.Transformer

    # Get multi_selects and toggles from states section
    all_states = Transformer.get_entities(dsl_state, [:states]) || []
    multi_selects = Enum.filter(all_states, &match?(%Lavash.State.MultiSelect{}, &1))
    toggles = Enum.filter(all_states, &match?(%Lavash.State.Toggle{}, &1))

    # Get actions (for optimistic action JS generation)
    actions = Transformer.get_entities(dsl_state, [:actions]) || []

    # Filter to optimistic actions (exclude those handled by multi_select/toggle)
    multi_select_names = Enum.map(multi_selects, & &1.name)
    toggle_names = Enum.map(toggles, & &1.name)
    excluded_names =
      (Enum.map(multi_select_names, &:"toggle_#{&1}") ++
       Enum.map(multi_select_names, &:"set_#{&1}") ++
       Enum.map(toggle_names, &:"toggle_#{&1}") ++
       Enum.map(toggle_names, &:"set_#{&1}"))
      |> MapSet.new()

    optimistic_actions =
      actions
      |> Enum.filter(&action_is_optimistic?/1)
      |> Enum.reject(&MapSet.member?(excluded_names, &1.name))

    # Get calculations (only those with optimistic: true)
    calculations =
      (Transformer.get_entities(dsl_state, [:calculations]) || [])
      |> Enum.filter(& &1.optimistic)

    # Get forms for validation generation
    forms = Transformer.get_entities(dsl_state, [:forms]) || []

    # Get extend_errors
    extend_errors = Transformer.get_entities(dsl_state, [:extend_errors_declarations]) || []

    # Get animated field configs (persisted by ExpandAnimatedStates transformer)
    animated_fields = Transformer.get_persisted(dsl_state, :lavash_animated_fields) || []

    # Get defrx definitions from persisted state
    # They are stored as {:lavash_defrx, name, arity} => {params, body_source}
    defrx_map = get_defrx_map(dsl_state)

    # If nothing to generate, return nil
    if multi_selects == [] and toggles == [] and calculations == [] and forms == [] and animated_fields == [] and optimistic_actions == [] do
      nil
    else
      # Use JsGenerator's internal logic to generate JS
      # We need to call it with the module so it can access __lavash__ functions
      # But since we're in a transformer, the module isn't compiled yet.
      # So we need to generate the JS ourselves from the DSL state.
      generate_js_code(multi_selects, toggles, calculations, forms, extend_errors, animated_fields, defrx_map, optimistic_actions, module)
    end
  end

  # Extract defrx definitions from module attributes via the env in persisted state
  defp get_defrx_map(dsl_state) do
    # The env is persisted by Spark and contains access to module attributes
    env = Spark.Dsl.Transformer.get_persisted(dsl_state, :env)

    if env do
      # Get the lavash_defrx module attribute
      # Format: {name, arity, params, body_ast, body_source}
      defrx_list = Module.get_attribute(env.module, :lavash_defrx) || []

      Enum.reduce(defrx_list, %{}, fn {name, arity, params, _body_ast, body_source}, acc ->
        Map.put(acc, {name, arity}, {params, body_source})
      end)
    else
      %{}
    end
  end

  defp generate_js_code(multi_selects, toggles, calculations, forms, extend_errors, animated_fields, defrx_map, optimistic_actions, _module) do
    # Generate JS for each type
    multi_select_action_fns = Enum.map(multi_selects, &generate_multi_select_action_js/1)
    multi_select_derive_fns = Enum.map(multi_selects, &generate_multi_select_derive_js/1)
    toggle_action_fns = Enum.map(toggles, &generate_toggle_action_js/1)
    toggle_derive_fns = Enum.map(toggles, &generate_toggle_derive_js/1)
    calculation_fns = Enum.map(calculations, &generate_calculation_js(&1, defrx_map)) |> Enum.filter(& &1)

    # Generate JS for optimistic actions
    action_fns = Enum.map(optimistic_actions, &generate_action_js/1) |> Enum.filter(& &1)

    # Generate form validation JS
    {form_validation_fns, form_error_fns, validation_derives, error_derives} =
      generate_form_validation_js(forms, extend_errors, defrx_map)

    fns =
      action_fns ++
        multi_select_action_fns ++
        multi_select_derive_fns ++
        toggle_action_fns ++
        toggle_derive_fns ++
        calculation_fns ++
        form_validation_fns ++
        form_error_fns

    # Allow generating just animated metadata (for components with animated state)
    if fns == [] and animated_fields == [] do
      nil
    else
      # Build derive names
      multi_select_derive_names = Enum.map(multi_selects, fn ms -> "#{ms.name}_chips" end)
      toggle_derive_names = Enum.map(toggles, fn t -> "#{t.name}_chip" end)

      calculation_derive_names =
        Enum.map(calculations, fn calc -> to_string(calc.name) end)

      derive_names =
        multi_select_derive_names ++
          toggle_derive_names ++ calculation_derive_names ++ validation_derives ++ error_derives

      # Build graph entries
      graph_entries = build_graph_entries(multi_selects, toggles, calculations, forms, extend_errors)

      # Build animated field metadata for JS
      # Format: [{ field: "open", phaseField: "open_phase", async: null, preserveDom: false, duration: 200 }, ...]
      animated_metadata = build_animated_metadata(animated_fields)

      fns_str = Enum.join(fns, ",\n")
      derives_str = Jason.encode!(derive_names)
      fields_str = Jason.encode!([])
      graph_str = Jason.encode!(graph_entries)
      animated_str = Jason.encode!(animated_metadata)

      """
      export default {
      #{fns_str}#{if fns_str != "", do: ",", else: ""}
      __derives__: #{derives_str},
      __fields__: #{fields_str},
      __graph__: #{graph_str},
      __animated__: #{animated_str}
      };
      """
    end
  end

  # Build animated field metadata for JS consumption
  defp build_animated_metadata(animated_fields) do
    Enum.map(animated_fields, fn config ->
      %{
        field: to_string(config.field),
        phaseField: to_string(config.phase_field),
        async: config.async && to_string(config.async),
        preserveDom: config.preserve_dom,
        duration: config.duration,
        type: config.type && to_string(config.type)
      }
    end)
  end

  # Check if an action is optimistic (has simple set/update, no side effects)
  defp action_is_optimistic?(action) do
    has_side_effects =
      (action.submits || []) != [] or
      (action.navigates || []) != [] or
      (action.effects || []) != [] or
      (action.invokes || []) != []

    has_set_or_update = (action.sets || []) != [] or (action.updates || []) != []

    # Check if action has runs with reads declared at action level
    runs = action.runs || []
    reads = action.reads || []
    has_transpilable_runs = runs != [] and reads != []

    has_operations = has_set_or_update or has_transpilable_runs

    !has_side_effects and has_operations
  end

  # Generate JS for an action
  defp generate_action_js(action) do
    name = action.name
    sets = action.sets || []
    updates = action.updates || []
    params = action.params || []

    # Generate JS expressions for sets and updates
    set_exprs = Enum.map(sets, &generate_set_js/1)
    update_exprs = Enum.map(updates, &generate_update_js/1)

    all_exprs = set_exprs ++ update_exprs

    # If any expression is nil (not transpilable), skip this action
    if Enum.any?(all_exprs, &is_nil/1) do
      nil
    else
      expr_pairs = Enum.join(all_exprs, ", ")
      param_str = if params != [], do: ", value", else: ""

      """
        #{name}(state#{param_str}) {
          return { #{expr_pairs} };
        }
      """
    end
  end

  # Generate JS for a set operation
  defp generate_set_js(set) do
    field = set.field
    value = set.value

    case analyze_value(value) do
      {:literal, v} ->
        "#{field}: #{Jason.encode!(v)}"

      :from_params_value ->
        "#{field}: Number(value)"

      :unknown ->
        nil
    end
  end

  # Generate JS for an update operation (increment/decrement)
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

  # Analyze a value to determine how to generate JS
  defp analyze_value(value)
       when is_number(value) or is_binary(value) or is_boolean(value) or is_atom(value) do
    {:literal, value}
  end

  defp analyze_value(value) when is_function(value, 1) do
    # Test with a mock context that has params.value
    try do
      test_ctx = %{params: %{value: "__TEST_VALUE__"}, state: %{}}
      result = value.(test_ctx)

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
    try do
      result_0 = fun.(0)
      result_10 = fun.(10)
      result_100 = fun.(100)

      delta1 = result_0 - 0
      delta2 = result_10 - 10
      delta3 = result_100 - 100

      if delta1 == delta2 and delta2 == delta3 do
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
  # JS Generation helpers (copied from JsGenerator)
  # ============================================

  @default_chip_class [
    base: "px-3 py-1.5 text-sm rounded-full border transition-colors cursor-pointer",
    active: "bg-primary text-primary-content border-primary",
    inactive: "bg-base-100 text-base-content/70 border-base-300 hover:border-primary/50"
  ]

  defp generate_multi_select_action_js(%Lavash.State.MultiSelect{} = ms) do
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

  defp generate_multi_select_derive_js(%Lavash.State.MultiSelect{} = ms) do
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

  defp generate_toggle_action_js(%Lavash.State.Toggle{} = toggle) do
    action_name = "toggle_#{toggle.name}"
    field = toggle.name

    """
      #{action_name}(state) {
        return { #{field}: !state.#{field} };
      }
    """
  end

  defp generate_toggle_derive_js(%Lavash.State.Toggle{} = toggle) do
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

  defp generate_calculation_js(calc, defrx_map) do
    name = calc.name
    source = calc.rx.source

    # Expand any defrx calls in the source before transpiling
    expanded_source = expand_defrx_in_source(source, defrx_map)

    # Use the existing elixir_to_js transpiler
    js_expr = Lavash.Rx.Transpiler.to_js(expanded_source)

    """
      #{name}(state) {
        return #{js_expr};
      }
    """
  end

  # Expand defrx function calls in the source string
  defp expand_defrx_in_source(source, defrx) when map_size(defrx) == 0, do: source

  defp expand_defrx_in_source(source, defrx) do
    # Parse the source, expand defrx calls, and convert back to string
    case Code.string_to_quoted(source) do
      {:ok, ast} ->
        expanded_ast = do_expand_defrx(ast, defrx)
        Macro.to_string(expanded_ast)

      {:error, _} ->
        source
    end
  end

  # Recursively expand defrx calls in AST
  defp do_expand_defrx({name, meta, args}, defrx) when is_atom(name) and is_list(args) do
    arity = length(args)
    expanded_args = Enum.map(args, &do_expand_defrx(&1, defrx))

    case Map.get(defrx, {name, arity}) do
      {params, body_source} ->
        # Parse the body source
        case Code.string_to_quoted(body_source) do
          {:ok, body_ast} ->
            # Substitute params with args
            substitutions = Enum.zip(params, expanded_args) |> Map.new()
            substitute_defrx_vars(body_ast, substitutions)

          {:error, _} ->
            {name, meta, expanded_args}
        end

      nil ->
        {name, meta, expanded_args}
    end
  end

  defp do_expand_defrx({form, meta, args}, defrx) when is_list(args) do
    {do_expand_defrx(form, defrx), meta, Enum.map(args, &do_expand_defrx(&1, defrx))}
  end

  defp do_expand_defrx({left, right}, defrx) do
    {do_expand_defrx(left, defrx), do_expand_defrx(right, defrx)}
  end

  defp do_expand_defrx(list, defrx) when is_list(list) do
    Enum.map(list, &do_expand_defrx(&1, defrx))
  end

  defp do_expand_defrx(other, _defrx), do: other

  # Substitute variable references with their values
  defp substitute_defrx_vars({var_name, meta, context}, substitutions)
       when is_atom(var_name) and is_atom(context) do
    case Map.get(substitutions, var_name) do
      nil -> {var_name, meta, context}
      value -> value
    end
  end

  defp substitute_defrx_vars({form, meta, args}, substitutions) when is_list(args) do
    {substitute_defrx_vars(form, substitutions), meta,
     Enum.map(args, &substitute_defrx_vars(&1, substitutions))}
  end

  defp substitute_defrx_vars({left, right}, substitutions) do
    {substitute_defrx_vars(left, substitutions), substitute_defrx_vars(right, substitutions)}
  end

  defp substitute_defrx_vars(list, substitutions) when is_list(list) do
    Enum.map(list, &substitute_defrx_vars(&1, substitutions))
  end

  defp substitute_defrx_vars(other, _substitutions), do: other

  defp generate_form_validation_js(forms, extend_errors, defrx_map) do
    # Build extend_errors map
    extend_errors_map =
      extend_errors
      |> Enum.map(fn ext -> {ext.field, ext.errors} end)
      |> Map.new()

    {validation_fns, error_fns, validation_derives, error_derives} =
      Enum.reduce(forms, {[], [], [], []}, fn form, {v_fns, e_fns, v_derives, e_derives} ->
        resource = form.resource
        form_name = form.name
        params_field = :"#{form_name}_params"
        create_action = form.create || :create
        skip_constraints = form.skip_constraints || []

        if Code.ensure_loaded?(resource) and
             function_exported?(resource, :spark_dsl_config, 0) do
          validations = Lavash.Form.ConstraintTranspiler.extract_validations(resource)

          # Get Ash validations with custom messages
          ash_validations = Lavash.Form.ValidationTranspiler.extract_validations_for_action(resource, create_action)

          # Generate per-field validation and error derives
          {field_v_fns, field_e_fns, field_v_derives, field_e_derives} =
            Enum.reduce(validations, {[], [], [], []}, fn validation,
                                                          {vf, ef, vd, ed} ->
              v_name = :"#{form_name}_#{validation.field}_valid"
              e_name = :"#{form_name}_#{validation.field}_errors"
              custom_errors = Map.get(extend_errors_map, e_name, [])
              field_ash_validations = Map.get(ash_validations, validation.field, [])

              # Check if this field should skip constraint-based validation
              skip_field_constraints = validation.field in skip_constraints

              v_fn = generate_field_validation_js(v_name, params_field, validation, skip_field_constraints)
              e_fn = generate_field_errors_js(e_name, params_field, validation, custom_errors, field_ash_validations, skip_field_constraints, defrx_map)

              {[v_fn | vf], [e_fn | ef], [to_string(v_name) | vd], [to_string(e_name) | ed]}
            end)

          # Generate combined form_valid if we have field validations
          {combined_v, combined_e, combined_v_d, combined_e_d} =
            if length(validations) > 0 do
              field_names = Enum.map(validations, & &1.field)
              form_valid_name = "#{form_name}_valid"
              form_errors_name = "#{form_name}_errors"

              v_checks =
                field_names
                |> Enum.map(fn field -> "state.#{form_name}_#{field}_valid" end)
                |> Enum.join(" && ")

              e_arrays =
                field_names
                |> Enum.map(fn field -> "...(state.#{form_name}_#{field}_errors || [])" end)
                |> Enum.join(", ")

              v_fn = """
                #{form_valid_name}(state) {
                  return #{v_checks};
                }
              """

              e_fn = """
                #{form_errors_name}(state) {
                  return [#{e_arrays}];
                }
              """

              {[v_fn], [e_fn], [form_valid_name], [form_errors_name]}
            else
              {[], [], [], []}
            end

          {
            v_fns ++ field_v_fns ++ combined_v,
            e_fns ++ field_e_fns ++ combined_e,
            v_derives ++ field_v_derives ++ combined_v_d,
            e_derives ++ field_e_derives ++ combined_e_d
          }
        else
          {v_fns, e_fns, v_derives, e_derives}
        end
      end)

    {validation_fns, error_fns, validation_derives, error_derives}
  end

  defp generate_field_validation_js(name, params_field, validation, skip_constraints) do
    field = validation.field
    field_str = to_string(field)
    required = validation.required
    type = validation.type
    constraints = validation.constraints

    value_expr = "state.#{params_field}?.[#{Jason.encode!(field_str)}]"

    checks = []

    # Required check is always included (it's about presence, not constraints)
    checks =
      if required do
        check = "(#{value_expr} != null && String(#{value_expr}).trim().length > 0)"
        [check | checks]
      else
        checks
      end

    # Type-specific constraint checks are skipped if skip_constraints is true
    checks =
      if skip_constraints do
        checks
      else
        case type do
          :string -> build_string_constraint_checks(value_expr, constraints, checks)
          :integer -> build_integer_constraint_checks(value_expr, constraints, checks)
          _ -> checks
        end
      end

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

  defp generate_field_errors_js(name, params_field, validation, custom_errors, ash_validations, skip_constraints, defrx_map) do
    field = validation.field
    field_str = to_string(field)
    required = validation.required
    type = validation.type
    constraints = validation.constraints

    value_expr = "state.#{params_field}?.[#{Jason.encode!(field_str)}]"

    # Build lookup for custom messages from Ash validations
    ash_messages = build_ash_message_lookup(ash_validations)

    error_checks = []

    # Required check is always included (it's about presence, not constraints)
    error_checks =
      if required do
        msg = Map.get(ash_messages, :required) ||
              Lavash.Form.ConstraintTranspiler.error_message(:required, nil)

        check =
          "{check: #{value_expr} != null && String(#{value_expr}).trim().length > 0, msg: #{Jason.encode!(msg)}}"

        [check | error_checks]
      else
        error_checks
      end

    # Type-specific constraint error checks are skipped if skip_constraints is true
    error_checks =
      if skip_constraints do
        error_checks
      else
        case type do
          :string -> build_string_error_checks(value_expr, constraints, error_checks, ash_messages)
          :integer -> build_integer_error_checks(value_expr, constraints, error_checks, ash_messages)
          _ -> error_checks
        end
      end

    # Add custom error checks - use defrx_map from DSL state for expansion
    error_checks =
      Enum.reduce(custom_errors, error_checks, fn error, acc ->
        expanded_condition = expand_defrx_in_source(error.condition.source, defrx_map)
        js_condition = Lavash.Rx.Transpiler.to_js(expanded_condition)

        msg_js =
          case error.message do
            %Lavash.Rx{source: source} ->
              expanded_msg = expand_defrx_in_source(source, defrx_map)
              "(#{Lavash.Rx.Transpiler.to_js(expanded_msg)})"

            static_string when is_binary(static_string) ->
              Jason.encode!(static_string)
          end

        check = "{check: !(#{js_condition}), msg: #{msg_js}}"
        [check | acc]
      end)

    checks_array = "[" <> Enum.join(Enum.reverse(error_checks), ", ") <> "]"

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

  defp build_string_error_checks(value_expr, constraints, checks, ash_messages) do
    checks =
      case Map.get(constraints, :min_length) do
        nil ->
          checks

        min ->
          msg = Map.get(ash_messages, :min_length) ||
                Map.get(ash_messages, :length_between) ||
                Lavash.Form.ConstraintTranspiler.error_message(:min_length, min)

          check =
            "{check: String(#{value_expr} || '').trim().length >= #{min}, msg: #{Jason.encode!(msg)}}"

          [check | checks]
      end

    checks =
      case Map.get(constraints, :max_length) do
        nil ->
          checks

        max ->
          msg = Map.get(ash_messages, :max_length) ||
                Map.get(ash_messages, :length_between) ||
                Lavash.Form.ConstraintTranspiler.error_message(:max_length, max)

          check =
            "{check: String(#{value_expr} || '').trim().length <= #{max}, msg: #{Jason.encode!(msg)}}"

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
  defp build_ash_message_lookup(ash_validations) do
    Enum.reduce(ash_validations, %{}, fn spec, acc ->
      if spec.message do
        message = Lavash.Form.ValidationTranspiler.get_message(spec)
        Map.put(acc, spec.type, message)
      else
        acc
      end
    end)
  end

  defp build_graph_entries(multi_selects, toggles, calculations, forms, extend_errors) do
    multi_select_entries =
      Enum.map(multi_selects, fn ms ->
        {"#{ms.name}_chips", %{deps: [to_string(ms.name)]}}
      end)

    toggle_entries =
      Enum.map(toggles, fn t ->
        {"#{t.name}_chip", %{deps: [to_string(t.name)]}}
      end)

    calculation_entries =
      Enum.map(calculations, fn calc ->
        deps =
          calc.rx.deps
          |> Enum.map(&normalize_dep_to_string/1)
          |> Enum.uniq()

        {to_string(calc.name), %{deps: deps}}
      end)

    # Build a map of field_name => extra deps from extend_errors
    extend_errors_deps =
      extend_errors
      |> Enum.map(fn ext ->
        # Collect all deps from the error conditions and messages
        deps =
          ext.errors
          |> Enum.flat_map(fn error ->
            condition_deps = error.condition.deps |> Enum.map(&normalize_dep_to_string/1)

            message_deps =
              case error.message do
                %Lavash.Rx{deps: deps} -> Enum.map(deps, &normalize_dep_to_string/1)
                _ -> []
              end

            condition_deps ++ message_deps
          end)
          |> Enum.uniq()

        {ext.field, deps}
      end)
      |> Map.new()

    form_entries =
      Enum.flat_map(forms, fn form ->
        form_name = form.name
        params_field = "#{form_name}_params"
        resource = form.resource

        if Code.ensure_loaded?(resource) and function_exported?(resource, :spark_dsl_config, 0) do
          validations = Lavash.Form.ConstraintTranspiler.extract_validations(resource)
          field_names = Enum.map(validations, & &1.field)

          field_v_entries =
            Enum.map(field_names, fn field ->
              {"#{form_name}_#{field}_valid", %{deps: [params_field]}}
            end)

          field_e_entries =
            Enum.map(field_names, fn field ->
              e_name = :"#{form_name}_#{field}_errors"
              # Include deps from extend_errors if this field has custom errors
              extra_deps = Map.get(extend_errors_deps, e_name, [])
              {"#{form_name}_#{field}_errors", %{deps: [params_field | extra_deps] |> Enum.uniq()}}
            end)

          combined_v =
            if length(field_names) > 0 do
              deps = Enum.map(field_names, fn field -> "#{form_name}_#{field}_valid" end)
              [{"#{form_name}_valid", %{deps: deps}}]
            else
              []
            end

          combined_e =
            if length(field_names) > 0 do
              deps = Enum.map(field_names, fn field -> "#{form_name}_#{field}_errors" end)
              [{"#{form_name}_errors", %{deps: deps}}]
            else
              []
            end

          field_v_entries ++ field_e_entries ++ combined_v ++ combined_e
        else
          []
        end
      end)

    (multi_select_entries ++ toggle_entries ++ calculation_entries ++ form_entries)
    |> Map.new()
  end

  defp normalize_dep_to_string({:path, root, _path}), do: to_string(root)
  defp normalize_dep_to_string(atom) when is_atom(atom), do: to_string(atom)
end
