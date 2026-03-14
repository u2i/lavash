defmodule Lavash.Optimistic.Transformers.ExtractColocatedJs do
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
  alias Lavash.Optimistic.{ActionJs, StateJs}
  alias Lavash.Form.ValidationJs

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
      |> Enum.filter(&ActionJs.action_is_optimistic?/1)
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
    multi_select_action_fns = Enum.map(multi_selects, &StateJs.generate_multi_select_action_js/1)
    multi_select_derive_fns = Enum.map(multi_selects, &StateJs.generate_multi_select_derive_js/1)
    toggle_action_fns = Enum.map(toggles, &StateJs.generate_toggle_action_js/1)
    toggle_derive_fns = Enum.map(toggles, &StateJs.generate_toggle_derive_js/1)
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
      animated_str = Jason.encode!(animated_metadata)

      # Flatten deps map: %{"name" => %{deps: [...]}} -> %{"name" => [...]}
      flat_deps = Map.new(graph_entries.deps, fn {name, %{deps: d}} -> {name, d} end)
      graph_json = Jason.encode!(%{
        topo_order: graph_entries.topo_order,
        deps: flat_deps,
        dependents: graph_entries.dependents
      })

      """
      export default {
      #{fns_str}#{if fns_str != "", do: ",", else: ""}
      __derives__: #{derives_str},
      __graph__: #{graph_json},
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

  # Generate JS for an action
  defp generate_action_js(action) do
    name = action.name
    sets = action.sets || []
    updates = action.updates || []
    params = action.params || []

    # Generate JS expressions for sets and updates
    set_exprs = Enum.map(sets, &generate_set_js(&1, params))
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
  defp generate_set_js(set, action_params) do
    field = set.field

    case ActionJs.analyze_value(set.value) do
      {:literal, v} ->
        "#{field}: #{Jason.encode!(v)}"

      :from_params_value ->
        "#{field}: Number(value)"

      {:rx, source} ->
        js_expr = Lavash.Rx.Transpiler.to_js(source)
        js_expr = case action_params do
          [param] -> String.replace(js_expr, "state.#{param}", "value")
          _ -> js_expr
        end
        "#{field}: #{js_expr}"

      :unknown ->
        nil
    end
  end

  defp generate_update_js(update), do: ActionJs.generate_update_js(update)

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

        if resource_available?(resource) do
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
              e_fn = generate_field_errors_js(e_name, params_field, form_name, validation, custom_errors, field_ash_validations, skip_field_constraints, defrx_map)

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

  # Form validation/error JS - delegate to ValidationJs

  defp generate_field_validation_js(name, params_field, validation, skip_constraints) do
    ValidationJs.generate_field_validation_js(name, params_field, validation, skip_constraints)
  end

  defp generate_field_errors_js(name, params_field, form_name, validation, custom_errors, ash_validations, skip_constraints, defrx_map) do
    expand_defrx = &expand_defrx_in_source(&1, defrx_map)

    ValidationJs.generate_field_errors_js(name, params_field, validation, custom_errors, ash_validations, skip_constraints,
      expand_defrx: expand_defrx,
      server_errors_field: "#{form_name}_server_errors"
    )
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

        if resource_available?(resource) do
          validations = Lavash.Form.ConstraintTranspiler.extract_validations(resource)
          field_names = Enum.map(validations, & &1.field)

          field_v_entries =
            Enum.map(field_names, fn field ->
              {"#{form_name}_#{field}_valid", %{deps: [params_field]}}
            end)

          server_errors_field = "#{form_name}_server_errors"

          field_e_entries =
            Enum.map(field_names, fn field ->
              e_name = :"#{form_name}_#{field}_errors"
              # Include deps from extend_errors if this field has custom errors
              extra_deps = Map.get(extend_errors_deps, e_name, [])
              {"#{form_name}_#{field}_errors", %{deps: [params_field, server_errors_field | extra_deps] |> Enum.uniq()}}
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

    deps_map =
      (multi_select_entries ++ toggle_entries ++ calculation_entries ++ form_entries)
      |> Map.new()

    plain_deps = Map.new(deps_map, fn {name, %{deps: deps}} -> {name, deps} end)
    topo_order = Lavash.Graph.topo_sort(plain_deps)
    dependents = Lavash.Graph.build_dependents(plain_deps)

    %{topo_order: topo_order, deps: deps_map, dependents: dependents}
  end


  defp normalize_dep_to_string(dep), do: ActionJs.normalize_dep_to_string(dep)

  # Block until the resource module is compiled, avoiding compilation order races.
  # Code.ensure_compiled/1 waits for compilation to finish (unlike ensure_loaded?
  # which only checks if already loaded). Safe because Ash resources never depend
  # on Lavash LiveViews/Components, so no circular dependency risk.
  defp resource_available?(resource) do
    match?({:module, _}, Code.ensure_compiled(resource)) and
      function_exported?(resource, :spark_dsl_config, 0)
  end
end
