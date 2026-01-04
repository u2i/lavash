defmodule Lavash.Optimistic.ColocatedTransformer do
  @moduledoc """
  Spark transformer that extracts generated optimistic JS to colocated files.

  This runs at compile time and writes the generated JS functions to the
  phoenix-colocated directory, allowing them to be bundled by esbuild instead
  of being eval'd at runtime.

  The generated files follow the same structure as Phoenix.LiveView.ColocatedJS,
  allowing them to be imported in app.js and registered with window.Lavash.optimistic.
  """

  use Spark.Dsl.Transformer

  # Run after all entities are defined but before compilation finishes
  def after?(_), do: true
  def before?(_), do: false

  @doc """
  Transform the DSL state by extracting optimistic JS to a colocated file.
  """
  def transform(dsl_state) do
    module = Spark.Dsl.Transformer.get_persisted(dsl_state, :module)

    # Skip if module is not available (shouldn't happen)
    if is_nil(module) do
      {:ok, dsl_state}
    else
      extract_optimistic_js(dsl_state, module)
    end
  end

  defp extract_optimistic_js(dsl_state, module) do
    # Generate JS at compile time using the DSL state directly
    js_code = generate_js_from_dsl(dsl_state, module)

    if js_code do
      write_colocated_file(module, js_code)
    end

    {:ok, dsl_state}
  end

  defp generate_js_from_dsl(dsl_state, module) do
    # Get entities from DSL state
    alias Spark.Dsl.Transformer

    # Get multi_selects and toggles from states section
    all_states = Transformer.get_entities(dsl_state, [:states]) || []
    multi_selects = Enum.filter(all_states, &match?(%Lavash.MultiSelect{}, &1))
    toggles = Enum.filter(all_states, &match?(%Lavash.Toggle{}, &1))

    # Get calculations (only those with optimistic: true)
    calculations =
      (Transformer.get_entities(dsl_state, [:calculations]) || [])
      |> Enum.filter(& &1.optimistic)

    # Get forms for validation generation
    forms = Transformer.get_entities(dsl_state, [:forms]) || []

    # Get extend_errors
    extend_errors = Transformer.get_entities(dsl_state, [:extend_errors_declarations]) || []

    # Get defrx definitions from persisted state
    # They are stored as {:lavash_defrx, name, arity} => {params, body_source}
    defrx_map = get_defrx_map(dsl_state)

    # If nothing to generate, return nil
    if multi_selects == [] and toggles == [] and calculations == [] and forms == [] do
      nil
    else
      # Use JsGenerator's internal logic to generate JS
      # We need to call it with the module so it can access __lavash__ functions
      # But since we're in a transformer, the module isn't compiled yet.
      # So we need to generate the JS ourselves from the DSL state.
      generate_js_code(multi_selects, toggles, calculations, forms, extend_errors, defrx_map, module)
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

  defp generate_js_code(multi_selects, toggles, calculations, forms, extend_errors, defrx_map, _module) do
    # Generate JS for each type
    multi_select_action_fns = Enum.map(multi_selects, &generate_multi_select_action_js/1)
    multi_select_derive_fns = Enum.map(multi_selects, &generate_multi_select_derive_js/1)
    toggle_action_fns = Enum.map(toggles, &generate_toggle_action_js/1)
    toggle_derive_fns = Enum.map(toggles, &generate_toggle_derive_js/1)
    calculation_fns = Enum.map(calculations, &generate_calculation_js(&1, defrx_map)) |> Enum.filter(& &1)

    # Generate form validation JS
    {form_validation_fns, form_error_fns, validation_derives, error_derives} =
      generate_form_validation_js(forms, extend_errors, defrx_map)

    fns =
      multi_select_action_fns ++
        multi_select_derive_fns ++
        toggle_action_fns ++
        toggle_derive_fns ++
        calculation_fns ++
        form_validation_fns ++
        form_error_fns

    if fns == [] do
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

      fns_str = Enum.join(fns, ",\n")
      derives_str = Jason.encode!(derive_names)
      fields_str = Jason.encode!([])
      graph_str = Jason.encode!(graph_entries)

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

  # Write the JS file to the colocated directory
  defp write_colocated_file(module, js_code) do
    target_dir = colocated_target_dir()
    module_dir = Path.join(target_dir, inspect(module))

    # Use deterministic filename - one file per module
    filename = "optimistic.js"
    file_path = Path.join(module_dir, filename)

    # Only write if directory exists or can be created
    if File.dir?(target_dir) or create_target_dir(target_dir) do
      File.mkdir_p!(module_dir)

      # Clean up old hashed files (from previous versions)
      cleanup_old_hashed_files(module_dir)

      File.write!(file_path, js_code)

      # Update the manifest with this module
      store_colocated_data(module, filename)
    end
  end

  # Remove old optimistic_*.js files (hashed filenames from previous versions)
  defp cleanup_old_hashed_files(module_dir) do
    case File.ls(module_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.starts_with?(&1, "optimistic_"))
        |> Enum.each(fn old_file ->
          File.rm(Path.join(module_dir, old_file))
        end)

      {:error, _} ->
        :ok
    end
  end

  defp create_target_dir(target_dir) do
    case File.mkdir_p(target_dir) do
      :ok -> true
      {:error, _} -> false
    end
  end

  # Get the target directory for Lavash optimistic JS
  # We write to assets/js/lavash-optimistic instead of phoenix-colocated
  # to avoid being cleaned up by Phoenix's colocated compiler
  defp colocated_target_dir do
    # Write to assets/js/lavash-optimistic instead of phoenix-colocated
    app_root = File.cwd!()
    Path.join([app_root, "assets", "js", "lavash-optimistic"])
  end

  # Store file info and write manifest
  defp store_colocated_data(module, _filename) do
    target_dir = colocated_target_dir()
    manifest_path = Path.join(target_dir, "index.js")

    # Read existing manifest entries (if any)
    existing_entries =
      if File.exists?(manifest_path) do
        content = File.read!(manifest_path)
        # Parse existing entries from manifest
        # Format: import module_hash from "./ModuleName/filename.js"; registry["ModuleName"] = module_hash;
        Regex.scan(~r/registry\["([^"]+)"\]/, content)
        |> Enum.map(fn [_, name] -> name end)
        |> MapSet.new()
      else
        MapSet.new()
      end

    # Add current module to entries
    module_name = inspect(module)
    entries = MapSet.put(existing_entries, module_name)

    # Generate manifest content
    manifest_content = generate_manifest(entries, target_dir)
    File.write!(manifest_path, manifest_content)
  end

  defp generate_manifest(module_names, target_dir) do
    imports_and_registrations =
      module_names
      |> Enum.sort()
      |> Enum.map(fn module_name ->
        # Find the optimistic file for this module
        module_dir = Path.join(target_dir, module_name)
        file_path = Path.join(module_dir, "optimistic.js")

        if File.exists?(file_path) do
          import_name = "mod_" <> (:crypto.hash(:md5, module_name) |> Base.encode16(case: :lower) |> String.slice(0..7))
          {module_name, "optimistic.js", import_name}
        else
          nil
        end
      end)
      |> Enum.filter(& &1)

    imports =
      imports_and_registrations
      |> Enum.map(fn {module_name, filename, import_name} ->
        "import #{import_name} from \"./#{module_name}/#{filename}\";"
      end)
      |> Enum.join("\n")

    registrations =
      imports_and_registrations
      |> Enum.map(fn {module_name, _filename, import_name} ->
        "registry[\"#{module_name}\"] = #{import_name};"
      end)
      |> Enum.join("\n")

    """
    // Auto-generated by Lavash.Optimistic.ColocatedTransformer
    // Do not edit manually - regenerated on each compile
    const registry = {};

    #{imports}

    #{registrations}

    export default registry;
    """
  end

  # ============================================
  # JS Generation helpers (copied from JsGenerator)
  # ============================================

  @default_chip_class [
    base: "px-3 py-1.5 text-sm rounded-full border transition-colors cursor-pointer",
    active: "bg-primary text-primary-content border-primary",
    inactive: "bg-base-100 text-base-content/70 border-base-300 hover:border-primary/50"
  ]

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

  defp generate_toggle_action_js(%Lavash.Toggle{} = toggle) do
    action_name = "toggle_#{toggle.name}"
    field = toggle.name

    """
      #{action_name}(state) {
        return { #{field}: !state.#{field} };
      }
    """
  end

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

  defp generate_calculation_js(calc, defrx_map) do
    name = calc.name
    source = calc.rx.source

    # Expand any defrx calls in the source before transpiling
    expanded_source = expand_defrx_in_source(source, defrx_map)

    # Use the existing elixir_to_js transpiler
    js_expr = Lavash.Transpiler.to_js(expanded_source)

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

  defp generate_field_validation_js(name, params_field, validation, skip_constraints \\ false) do
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
        js_condition = Lavash.Transpiler.to_js(expanded_condition)

        msg_js =
          case error.message do
            %Lavash.Rx{source: source} ->
              expanded_msg = expand_defrx_in_source(source, defrx_map)
              "(#{Lavash.Transpiler.to_js(expanded_msg)})"

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
