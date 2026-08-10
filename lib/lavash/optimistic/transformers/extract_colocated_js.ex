defmodule Lavash.Optimistic.Transformers.ExtractColocatedJs do
  @moduledoc """
  Extracts generated optimistic JS to colocated files for esbuild bundling.

  Generates JS functions for actions, calculations, form validation,
  attr derives, and subtree derives, then writes them to the
  phoenix-colocated directory.

  Persists:
  - `:lavash_optimistic_colocated_data` — colocated file metadata for `__phoenix_macro_components__`
  """

  use Spark.Dsl.Transformer

  require Logger

  alias Lavash.Component.CompilerHelpers
  alias Lavash.Form.ValidationJs
  alias Lavash.Optimistic.ActionJs
  alias Spark.Dsl.Transformer

  # Run after AnalyzeTemplate but before CompileComponent
  def after?(Lavash.Component.Transformers.AnalyzeTemplate), do: true
  def after?(Lavash.Component.Transformers.TokenizeTemplate), do: true
  def after?(Lavash.Optimistic.Transformers.ExpandAnimatedStates), do: true
  def after?(Lavash.Transformers.ExpandFields), do: true
  def after?(_), do: false

  def before?(Lavash.Component.Transformers.CompileComponent), do: true
  def before?(_), do: false

  def transform(dsl_state) do
    module = Transformer.get_persisted(dsl_state, :module)
    env = Transformer.get_persisted(dsl_state, :env)

    cond do
      is_nil(module) or is_nil(env) ->
        {:ok, dsl_state}

      # `use Lavash.LiveView.Base` / `use Lavash.Component.Base`
      # opt out of layer 4. No optimistic JS, no colocated bundle.
      Module.get_attribute(module, :__lavash_layer__) == :base ->
        {:ok, dsl_state}

      true ->
        {:ok, extract_optimistic_js(dsl_state, module, env)}
    end
  end

  defp extract_optimistic_js(dsl_state, module, env) do
    # Generate JS at compile time using the DSL state directly
    js_code = generate_js_from_dsl(dsl_state, module)

    if js_code do
      # Fail the module's compilation if the generated JS doesn't parse.
      # Without this, invalid JS surfaces only in the consuming app's
      # bundler — whose failing watcher keeps serving a stale bundle.
      Lavash.Optimistic.JsValidator.validate!(js_code, module, env)

      # Use Phoenix's colocated system via CompilerHelpers
      # This writes to the same directory as other colocated hooks
      colocated_data = write_colocated_optimistic(env, module, js_code)

      # Persist the colocated data so we can include it in __phoenix_macro_components__
      Transformer.persist(dsl_state, :lavash_optimistic_colocated_data, colocated_data)
    else
      # No optimistic JS to generate - clean up any stale directory from previous compilations
      cleanup_stale_optimistic_dir(module)
      dsl_state
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

  # Write optimistic JS via Phoenix's colocated assets API.
  #
  # `Phoenix.LiveView.ColocatedAssets.extract/5` does TWO things:
  #
  #   1. Writes the file into the colocated target directory at the
  #      module's subfolder (same place we used to write it manually).
  #   2. Returns a `%Phoenix.LiveView.ColocatedAssets.Entry{}` struct
  #      that Phoenix's compile pass uses to track which files belong
  #      to which module. Files NOT registered through an Entry get
  #      deleted by `ColocatedAssets.compile/0`'s `process_module/2`
  #      cleanup — that's the bug we hit when writing manually with
  #      `File.write!`: lavash's file was deleted on every compile.
  #
  # The persisted Entry flows into `__phoenix_macro_components__/0`
  # (see CompileLiveView.build_colocated_ast/1) which is what
  # Phoenix walks at compile-time to assemble its manifest.
  defp write_colocated_optimistic(env, module, js_code) do
    # Generate filename with hash for cache busting.
    hash = :crypto.hash(:md5, js_code) |> Base.encode32(case: :lower, padding: false)
    filename = "optimistic_#{hash}.js"

    # Clean up any stale optimistic_*.js files (other hashes) before
    # writing the new one. Phoenix's process_module/2 would also clean
    # them up, but doing it here keeps the directory predictable
    # between compiles and avoids one unnecessary deletion on the
    # first compile after a content change.
    module_dir = Path.join(CompilerHelpers.get_target_dir(), inspect(module))

    case File.ls(module_dir) do
      {:ok, files} ->
        for file <- files, String.starts_with?(file, "optimistic_"), file != filename do
          File.rm(Path.join(module_dir, file))
        end

      _ ->
        :ok
    end

    # Phoenix's extract/5 writes the file (mkdir_p! + write!) and
    # returns the %Entry{} we persist for the macro_components hook.
    # Data shape (name + key) is what ColocatedJS.build_manifest uses
    # to group exports — `key: "optimistic"` puts our fns under the
    # `optimistic` named export of the manifest.
    Phoenix.LiveView.ColocatedAssets.extract(
      Phoenix.LiveView.ColocatedJS,
      env.module,
      filename,
      js_code,
      %{name: inspect(env.module), key: "optimistic"}
    )
  end

  defp generate_js_from_dsl(dsl_state, module) do
    alias Spark.Dsl.Transformer

    actions = Transformer.get_entities(dsl_state, [:actions]) || []

    optimistic_actions =
      actions
      |> Enum.filter(&ActionJs.action_is_optimistic?/1)

    calculations =
      (Transformer.get_entities(dsl_state, [:calculations]) || [])
      |> Enum.filter(& &1.optimistic)

    forms = Transformer.get_entities(dsl_state, [:forms]) || []
    extend_errors = Transformer.get_entities(dsl_state, [:extend_errors_declarations]) || []
    animated_fields = Transformer.get_persisted(dsl_state, :lavash_animated_fields) || []
    defrx_map = get_defrx_map(dsl_state)

    # Read reactive attribute derives from AnalyzeTemplate
    attr_derives =
      (Transformer.get_persisted(dsl_state, :lavash_attr_derives) || []) ++
        try do
          Module.get_attribute(module, :__lavash_attr_derives__) || []
        rescue
          _ -> []
        end

    # Read subtree derives (auto-extracted :if/:for over optimistic state)
    subtree_derives = Transformer.get_persisted(dsl_state, :lavash_subtree_derives) || []

    # Projection field -> key, for mutate/remove row matching
    projection_keys =
      (Transformer.get_entities(dsl_state, [:reads]) || [])
      |> Enum.flat_map(fn read ->
        Enum.map(read.client_states || [], fn cs -> {cs.name, cs.key} end)
      end)
      |> Map.new()

    if calculations == [] and forms == [] and animated_fields == [] and optimistic_actions == [] and
         attr_derives == [] and subtree_derives == [] do
      nil
    else
      generate_js_code(%{
        calculations: calculations,
        forms: forms,
        extend_errors: extend_errors,
        animated_fields: animated_fields,
        defrx_map: defrx_map,
        optimistic_actions: optimistic_actions,
        attr_derives: attr_derives,
        subtree_derives: subtree_derives,
        projection_keys: projection_keys,
        module: module
      })
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

  defp generate_js_code(%{
         calculations: calculations,
         forms: forms,
         extend_errors: extend_errors,
         animated_fields: animated_fields,
         defrx_map: defrx_map,
         optimistic_actions: optimistic_actions,
         attr_derives: attr_derives,
         subtree_derives: subtree_derives,
         projection_keys: projection_keys,
         module: module
       }) do
    # Demote untranspilable optimistic calcs to server-only, loudly:
    # a calc whose transpiled body contains the untranspilable marker
    # would evaluate to `undefined` client-side and clobber the
    # server-computed value on every recompute (issue #43). Demoted
    # calcs are excluded from the generated fns, derive names, AND the
    # dependency graph — the server value stays authoritative and
    # client-readable.
    {calculations, calculation_fns} =
      split_transpilable_calculations(calculations, defrx_map, module)

    action_fns =
      optimistic_actions
      |> Enum.map(&generate_action_js(&1, projection_keys))
      |> Enum.filter(& &1)

    {form_validation_fns, form_error_fns, validation_derives, error_derives} =
      generate_form_validation_js(forms, extend_errors, defrx_map)

    # Generate attr derive functions
    attr_derive_fns = Enum.map(attr_derives, &generate_attr_derive_js/1)

    # Generate subtree derive functions (auto-extracted :if/:for)
    subtree_derive_fns = Enum.map(subtree_derives, &generate_subtree_derive_js/1)

    fns =
      action_fns ++
        calculation_fns ++
        form_validation_fns ++
        form_error_fns ++
        attr_derive_fns ++
        subtree_derive_fns

    if fns == [] and animated_fields == [] do
      nil
    else
      calculation_derive_names =
        Enum.map(calculations, fn calc -> to_string(calc.name) end)

      attr_derive_names = Enum.map(attr_derives, fn d -> d.name end)
      subtree_derive_names = Enum.map(subtree_derives, fn d -> d.name end)

      derive_names =
        calculation_derive_names ++
          validation_derives ++ error_derives ++ attr_derive_names ++ subtree_derive_names

      graph_entries = build_graph_entries(calculations, forms, extend_errors)

      # Add attr derives to the graph
      graph_entries =
        Enum.reduce(attr_derives ++ subtree_derives, graph_entries, fn derive, graph ->
          deps = derive.deps
          name = derive.name

          updated_deps = Map.put(graph.deps, name, %{deps: deps})

          updated_dependents =
            Enum.reduce(deps, graph.dependents, fn dep, acc ->
              Map.update(acc, dep, [name], fn existing -> [name | existing] end)
            end)

          updated_topo = graph.topo_order ++ [name]
          %{graph | deps: updated_deps, dependents: updated_dependents, topo_order: updated_topo}
        end)

      # Build animated field metadata for JS
      # Format: [{ field: "open", phaseField: "open_phase", async: null, duration: 200 }, ...]
      animated_metadata = build_animated_metadata(animated_fields)

      fns_str = Enum.join(fns, ",\n")
      derives_str = Jason.encode!(derive_names)
      animated_str = Jason.encode!(animated_metadata)

      # Actions with appends apply their delta provisionally (seed, not
      # setOptimistic): the provisional row carries a temp key, so the
      # same event's re-read — with the real record — must be accepted,
      # not rejected as a mismatched prediction.
      provisional_str =
        optimistic_actions
        |> Enum.filter(&((Map.get(&1, :appends) || []) != []))
        |> Enum.map(&to_string(&1.name))
        |> Jason.encode!()

      # Flatten deps map: %{"name" => %{deps: [...]}} -> %{"name" => [...]}
      flat_deps = Map.new(graph_entries.deps, fn {name, %{deps: d}} -> {name, d} end)

      graph_json =
        Jason.encode!(%{
          topo_order: graph_entries.topo_order,
          deps: flat_deps,
          dependents: graph_entries.dependents
        })

      # The module self-registers into window.Lavash.optimistic at import
      # time, so a bare side-effect import of the colocated manifest
      # (`import "phoenix-colocated/my_app"`) is all an app needs. The
      # window guards
      # make import order relative to the lavash package irrelevant.
      """
      const fns = {
      #{fns_str}#{if fns_str != "", do: ",", else: ""}
      __derives__: #{derives_str},
      __graph__: #{graph_json},
      __animated__: #{animated_str},
      __provisional__: #{provisional_str}
      };
      window.Lavash = window.Lavash || {};
      window.Lavash.optimistic = window.Lavash.optimistic || {};
      window.Lavash.optimistic[#{Jason.encode!(inspect(module))}] = fns;
      export default fns;
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
        duration: config.duration,
        type: config.type && to_string(config.type)
      }
    end)
  end

  # Generate JS for an action
  # Non-transpilable sets (lambdas, complex expressions) are skipped —
  # the transpilable ones still run client-side for instant UI updates
  defp generate_action_js(action, projection_keys) do
    name = action.name
    sets = action.sets || []
    params = action.params || []

    # Generate JS expressions, filtering out non-transpilable ones
    set_exprs = sets |> Enum.map(&generate_set_js(&1, params)) |> Enum.filter(& &1)

    projection_ops =
      Enum.map(Map.get(action, :mutates) || [], &generate_mutate_js(&1, params, projection_keys)) ++
        Enum.map(Map.get(action, :removes) || [], &generate_remove_js(&1, projection_keys)) ++
        Enum.map(
          Map.get(action, :appends) || [],
          &generate_append_js(&1, params, projection_keys)
        )

    projection_stmts = Enum.filter(projection_ops, & &1)

    if set_exprs == [] and projection_stmts == [] do
      nil
    else
      param_str = if params != [], do: ", value", else: ""
      method_key = Lavash.Optimistic.Transpiler.js_field_key(name)

      if projection_stmts != [] do
        # Projection ops mutate the list in-place and return the full delta
        stmts = Enum.join(projection_stmts, "\n")

        projection_fields =
          Lavash.ClientState.mutated_fields(action)
          |> Enum.uniq()
          |> Enum.map(fn field ->
            "#{Lavash.Optimistic.Transpiler.js_field_key(field)}: #{Lavash.Optimistic.Transpiler.js_field_access("state", field)}"
          end)

        set_delta = if set_exprs != [], do: Enum.join(set_exprs, ", ") <> ", ", else: ""
        projection_delta = Enum.join(projection_fields, ", ")

        """
          #{method_key}(state#{param_str}) {
        #{stmts}
            return { #{set_delta}#{projection_delta} };
          }
        """
      else
        expr_pairs = Enum.join(set_exprs, ", ")

        """
          #{method_key}(state#{param_str}) {
            return { #{expr_pairs} };
          }
        """
      end
    end
  end

  # The transform rx sees the matched row as @item. Transpiled, @item
  # refs become `state.item` accesses — we evaluate the expression with
  # a shadowed state that has the row injected, so both @item and
  # ordinary state refs resolve.
  defp generate_mutate_js(mutate, params, projection_keys) do
    field = mutate.field
    key = projection_key_js(projection_keys, field)
    state_field = Lavash.Optimistic.Transpiler.js_field_access("state", field)
    transform_js = transpile_projection_rx(mutate.transform, params, "mutate :#{field}")

    if transform_js do
      """
          #{state_field} = (#{state_field} || []).map(item => {
            if (String(#{key}) === String(value)) {
              const result = ((state) => (#{transform_js}))({ ...state, item: item });
              return result === 'remove' ? null : { ...item, ...result };
            }
            return item;
          }).filter(item => item !== null);
      """
    else
      nil
    end
  end

  defp generate_remove_js(remove, projection_keys) do
    key = projection_key_js(projection_keys, remove.field)
    state_field = Lavash.Optimistic.Transpiler.js_field_access("state", remove.field)

    "    #{state_field} = (#{state_field} || []).filter(item => String(#{key}) !== String(value));"
  end

  # The provisional row gets a temp key; runOptimisticAction applies
  # provisional deltas via seed() (non-pending), so the same event's
  # re-read — carrying the real record — is accepted, not rejected.
  defp generate_append_js(append, params, projection_keys) do
    field = append.field
    key_name = Map.get(projection_keys, field, :id)
    state_field = Lavash.Optimistic.Transpiler.js_field_access("state", field)
    transform_js = transpile_projection_rx(append.transform, params, "append :#{field}")

    if transform_js do
      """
          #{state_field} = [ ...(#{state_field} || []),
            { #{Lavash.Optimistic.Transpiler.js_field_key(key_name)}: "__lavash_tmp_" + Date.now() + "_" + Math.floor(Math.random() * 1e6),
              ...(#{transform_js}) } ];
      """
    else
      nil
    end
  end

  defp projection_key_js(projection_keys, field) do
    key_name = Map.get(projection_keys, field, :id)
    Lavash.Optimistic.Transpiler.js_field_access("item", to_string(key_name))
  end

  defp transpile_projection_rx(%Lavash.Rx{source: source}, params, label) do
    js_expr = Lavash.Optimistic.Transpiler.to_js(source)

    js_expr =
      case params do
        [param] ->
          param_ref = Lavash.Optimistic.Transpiler.js_field_access("state", param)
          String.replace(js_expr, param_ref, "value")

        _ ->
          js_expr
      end

    if Lavash.Optimistic.Transpiler.untranspilable_output?(js_expr) do
      Logger.warning(
        "[lavash] #{label} uses rx(#{source}) which is not transpilable; the " <>
          "prediction is skipped client-side and the list only updates after " <>
          "the server round-trip."
      )

      nil
    else
      js_expr
    end
  end

  # Generate JS for a set operation
  defp generate_set_js(set, action_params) do
    field = set.field
    key = Lavash.Optimistic.Transpiler.js_field_key(field)

    case ActionJs.analyze_value(set.value) do
      {:literal, v} ->
        "#{key}: #{Jason.encode!(v)}"

      :from_params_value ->
        "#{key}: value"

      {:rx, source} ->
        js_expr = Lavash.Optimistic.Transpiler.to_js(source)

        js_expr =
          case action_params do
            [param] ->
              # The action's single param appears in the rx body as
              # `@param` → `state.param` (or `state["param?"]`). Swap to
              # `value` so the action receives the param via the value
              # callsite parameter instead of via state.
              param_ref = Lavash.Optimistic.Transpiler.js_field_access("state", param)
              String.replace(js_expr, param_ref, "value")

            _ ->
              js_expr
          end

        if Lavash.Optimistic.Transpiler.untranspilable_output?(js_expr) do
          # Shipping this would apply `undefined` to the field on every
          # optimistic run of the action (issue #43). Skip the set —
          # the server still applies it — and say so.
          Logger.warning(
            "[lavash] set :#{field} in an optimistic action uses rx(#{source}) which is " <>
              "not transpilable; the set is skipped client-side and only applies after " <>
              "the server round-trip."
          )

          nil
        else
          "#{key}: #{js_expr}"
        end

      :unknown ->
        nil
    end
  end

  defp generate_attr_derive_js(%{name: name, js_expr: js_expr}) do
    method_key = Lavash.Optimistic.Transpiler.js_field_key(name)

    """
      #{method_key}(state) {
        return #{js_expr};
      }
    """
  end

  defp generate_subtree_derive_js(%{name: name, js_expr: js_expr}) do
    method_key = Lavash.Optimistic.Transpiler.js_field_key(name)

    """
      #{method_key}(state) {
        return #{js_expr};
      }
    """
  end

  # Transpile each optimistic calculation; calcs whose JS contains the
  # untranspilable marker are demoted (dropped from the client bundle)
  # with a warning. Returns {kept_calculations, generated_fns} so the
  # caller builds derive names and the graph from the SAME kept set.
  defp split_transpilable_calculations(calculations, defrx_map, module) do
    {kept, fns} =
      Enum.reduce(calculations, {[], []}, fn calc, {kept, fns} ->
        case generate_calculation_js(calc, defrx_map) do
          {:ok, js} ->
            {[calc | kept], [js | fns]}

          {:untranspilable, _js} ->
            Logger.warning(
              "[lavash] #{inspect(module)}: calculate :#{calc.name} is marked optimistic " <>
                "but rx(#{calc.rx.source}) is not transpilable; demoting to server-only. " <>
                "The value still updates via server patches. Mark it `optimistic: false` " <>
                "to silence this warning."
            )

            {kept, fns}
        end
      end)

    {Enum.reverse(kept), Enum.reverse(fns)}
  end

  defp generate_calculation_js(calc, defrx_map) do
    name = calc.name
    source = calc.rx.source

    # Expand any defrx calls in the source before transpiling
    expanded_source = expand_defrx_in_source(source, defrx_map)

    # Use the existing elixir_to_js transpiler
    js_expr = Lavash.Optimistic.Transpiler.to_js(expanded_source)
    method_key = Lavash.Optimistic.Transpiler.js_field_key(name)

    js = """
      #{method_key}(state) {
        return #{js_expr};
      }
    """

    if Lavash.Optimistic.Transpiler.untranspilable_output?(js_expr) do
      {:untranspilable, js}
    else
      {:ok, js}
    end
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

        if CompilerHelpers.resource_available?(resource) do
          action = Ash.Resource.Info.action(resource, create_action)
          accepted = if action, do: action.accept || [], else: []

          validations =
            Lavash.Form.ConstraintTranspiler.extract_validations(resource)
            |> Enum.filter(fn v -> accepted == [] or v.field in accepted end)

          # Get Ash validations with custom messages
          ash_validations =
            Lavash.Form.ValidationTranspiler.extract_validations_for_action(
              resource,
              create_action
            )

          # Generate per-field validation and error derives
          {field_v_fns, field_e_fns, field_v_derives, field_e_derives} =
            Enum.reduce(validations, {[], [], [], []}, fn validation, {vf, ef, vd, ed} ->
              v_name = :"#{form_name}_#{validation.field}_valid"
              e_name = :"#{form_name}_#{validation.field}_errors"
              custom_errors = Map.get(extend_errors_map, e_name, [])
              field_ash_validations = Map.get(ash_validations, validation.field, [])

              # Check if this field should skip constraint-based validation
              skip_field_constraints = validation.field in skip_constraints

              v_fn =
                generate_field_validation_js(
                  v_name,
                  params_field,
                  validation,
                  skip_field_constraints
                )

              e_fn =
                generate_field_errors_js(
                  e_name,
                  params_field,
                  form_name,
                  validation,
                  custom_errors,
                  field_ash_validations,
                  skip_field_constraints,
                  defrx_map
                )

              {[v_fn | vf], [e_fn | ef], [to_string(v_name) | vd], [to_string(e_name) | ed]}
            end)

          # Generate combined form_valid if we have field validations
          {combined_v, combined_e, combined_v_d, combined_e_d} =
            if validations != [] do
              field_names = Enum.map(validations, & &1.field)
              form_valid_name = "#{form_name}_valid"
              form_errors_name = "#{form_name}_errors"

              v_checks =
                Enum.map_join(field_names, " && ", fn field ->
                  "state.#{form_name}_#{field}_valid"
                end)

              e_arrays =
                Enum.map_join(field_names, ", ", fn field ->
                  "...(state.#{form_name}_#{field}_errors || [])"
                end)

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

  defp generate_field_errors_js(
         name,
         params_field,
         form_name,
         validation,
         custom_errors,
         ash_validations,
         skip_constraints,
         defrx_map
       ) do
    expand_defrx = &expand_defrx_in_source(&1, defrx_map)

    ValidationJs.generate_field_errors_js(
      name,
      params_field,
      validation,
      custom_errors,
      ash_validations,
      skip_constraints,
      expand_defrx: expand_defrx,
      server_errors_field: "#{form_name}_server_errors"
    )
  end

  defp build_graph_entries(calculations, forms, extend_errors) do
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

        if CompilerHelpers.resource_available?(resource) do
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

              {"#{form_name}_#{field}_errors",
               %{deps: [params_field, server_errors_field | extra_deps] |> Enum.uniq()}}
            end)

          combined_v =
            if field_names != [] do
              deps = Enum.map(field_names, fn field -> "#{form_name}_#{field}_valid" end)
              [{"#{form_name}_valid", %{deps: deps}}]
            else
              []
            end

          combined_e =
            if field_names != [] do
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
      (calculation_entries ++ form_entries)
      |> Map.new()

    plain_deps = Map.new(deps_map, fn {name, %{deps: deps}} -> {name, deps} end)
    topo_order = Lavash.Graph.topo_sort(plain_deps)
    dependents = Lavash.Graph.build_dependents(plain_deps)

    %{topo_order: topo_order, deps: deps_map, dependents: dependents}
  end

  defp normalize_dep_to_string(dep), do: ActionJs.normalize_dep_to_string(dep)
end
