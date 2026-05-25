defmodule Lavash.Transformers.ExpandFields do
  @moduledoc """
  Spark transformer that expands all DSL entities (reads, forms, calculations,
  explicit derives, multi_selects, toggles) into field specs at compile time.

  The transformer persists pure-data specs (no closures) via
  `Transformer.persist/3`. At runtime, `build_fields/1` converts these specs
  into `Lavash.Derived.Field` structs with compute closures — called once per
  module by `Dsl.Graph.compiled_graph` and cached in persistent_term.
  """

  use Spark.Dsl.Transformer
  alias Lavash.Component.CompilerHelpers
  alias Spark.Dsl.Transformer

  def after?(Lavash.Optimistic.Transformers.ExpandDefrx), do: true
  def after?(Lavash.Optimistic.Transformers.ExpandAnimatedStates), do: true
  def after?(_), do: false

  def before?(Lavash.Optimistic.Transformers.ExtractColocatedJs), do: true
  def before?(_), do: false

  # ============================================================
  # Compile-time: extract specs and persist
  # ============================================================

  def transform(dsl_state) do
    module = Transformer.get_persisted(dsl_state, :module)

    read_specs = extract_read_specs(dsl_state)
    form_specs = extract_form_specs(dsl_state)
    calc_specs = extract_calc_specs(dsl_state, module)
    specs = read_specs ++ form_specs ++ calc_specs
    dsl_state = Transformer.persist(dsl_state, :lavash_field_specs, specs)

    {:ok, dsl_state}
  end

  # --- Read spec extraction ---

  defp extract_read_specs(dsl_state) do
    reads = Transformer.get_entities(dsl_state, [:reads]) || []
    states = Transformer.get_entities(dsl_state, [:states]) || []
    state_names = MapSet.new(states, & &1.name)

    Enum.map(reads, fn read ->
      if read.id do
        extract_read_by_id_spec(read)
      else
        extract_read_query_spec(read, state_names)
      end
    end)
  end

  defp extract_read_by_id_spec(read) do
    resource = read.resource
    action = read.action || :read
    is_async = read.async != false

    case read.id do
      id_fun when is_function(id_fun, 1) ->
        %{
          type: :read_by_id_fn,
          name: read.name,
          depends_on: [:__all_state__, :__actor__],
          async: is_async,
          reads: [resource],
          resource: resource,
          action: action
        }

      id_source ->
        id_dep = extract_dependency(id_source)

        %{
          type: :read_by_id,
          name: read.name,
          depends_on: [id_dep, :__actor__],
          async: is_async,
          reads: [resource],
          resource: resource,
          action: action,
          id_dep: id_dep
        }
    end
  end

  defp extract_read_query_spec(read, state_names) do
    resource = read.resource
    action_name = read.action || :read
    is_async = read.async != false
    as_options = read.as_options

    action = Ash.Resource.Info.action(resource, action_name)
    action_type = if action, do: action.type, else: :read
    action_args = if action, do: action.arguments, else: []

    arg_overrides =
      (read.arguments || [])
      |> Enum.map(fn arg -> {arg.name, arg} end)
      |> Map.new()

    {depends_on, arg_mapping} =
      Enum.reduce(action_args, {[], []}, fn action_arg, {deps, mapping} ->
        arg_name = action_arg.name

        case Map.get(arg_overrides, arg_name) do
          nil ->
            if MapSet.member?(state_names, arg_name) do
              {[arg_name | deps], [{arg_name, arg_name, false} | mapping]}
            else
              {deps, mapping}
            end

          %{source: source, transform: transform} ->
            source_field = if source, do: extract_dependency(source), else: arg_name
            has_transform = not is_nil(transform)
            {[source_field | deps], [{arg_name, source_field, has_transform} | mapping]}
        end
      end)

    depends_on = (Enum.reverse(depends_on) ++ [:__actor__]) |> Enum.uniq()
    arg_mapping = Enum.reverse(arg_mapping)

    %{
      type: :read_query,
      name: read.name,
      depends_on: depends_on,
      async: is_async,
      reads: [resource],
      resource: resource,
      action_name: action_name,
      action_type: action_type,
      as_options: as_options,
      arg_mapping: arg_mapping
    }
  end

  # --- Form spec extraction ---

  defp extract_form_specs(dsl_state) do
    forms = Transformer.get_entities(dsl_state, [:forms]) || []

    extend_errors_map =
      (Transformer.get_entities(dsl_state, [:extend_errors_declarations]) || [])
      |> Enum.map(fn ext -> {ext.field, ext.errors} end)
      |> Map.new()

    Enum.flat_map(forms, &extract_single_form_specs(&1, extend_errors_map))
  end

  defp extract_single_form_specs(form, extend_errors_map) do
    data_dep = extract_dependency(form.data)

    params_dep =
      if form.params do
        extract_dependency(form.params)
      else
        :"#{form.name}_params"
      end

    depends_on =
      if data_dep do
        [data_dep, params_dep]
      else
        [params_dep]
      end

    resource = form.resource
    create_action = form.create || :create
    update_action = form.update || :update
    form_name = form.name

    form_spec = %{
      type: :form,
      name: form_name,
      depends_on: depends_on,
      async: false,
      reads: [resource],
      resource: resource,
      data_dep: data_dep,
      params_dep: params_dep,
      create: create_action,
      update: update_action,
      form_name_str: to_string(form_name)
    }

    validation_specs =
      extract_validation_specs(form, params_dep, extend_errors_map)

    [form_spec | validation_specs]
  end

  defp extract_validation_specs(form, params_dep, extend_errors_map) do
    resource = form.resource
    form_name = form.name
    create_action = form.create

    if CompilerHelpers.resource_available?(resource) do
      validations = Lavash.Form.ConstraintTranspiler.extract_validations(resource)

      ash_validations =
        Lavash.Form.ValidationTranspiler.extract_validations_for_action(
          resource,
          create_action
        )

      field_valid_specs =
        Enum.map(validations, fn validation ->
          %{
            type: :form_field_valid,
            name: :"#{form_name}_#{validation.field}_valid",
            depends_on: [params_dep],
            async: false,
            reads: [],
            optimistic: true,
            params_dep: params_dep,
            field_str: to_string(validation.field),
            val_type: validation.type,
            required: validation.required,
            constraints: validation.constraints
          }
        end)

      server_errors_dep = :"#{form_name}_server_errors"

      field_errors_specs =
        Enum.map(validations, fn validation ->
          field_name = :"#{form_name}_#{validation.field}_errors"
          custom_errors = Map.get(extend_errors_map, field_name, [])
          field_ash_validations = Map.get(ash_validations, validation.field, [])

          custom_error_deps =
            Enum.flat_map(custom_errors, fn error ->
              case error.condition do
                %Lavash.Rx{deps: deps} when is_list(deps) ->
                  Enum.map(deps, fn
                    {:path, var_name, _path} -> var_name
                    dep when is_atom(dep) -> dep
                  end)

                _ ->
                  []
              end
            end)
            |> Enum.uniq()

          # Extract AST-based custom error specs (all pure data)
          custom_error_specs =
            Enum.map(custom_errors, fn error ->
              message_spec =
                case error.message do
                  %Lavash.Rx{ast: ast} -> {:dynamic, ast}
                  static_string when is_binary(static_string) -> {:static, static_string}
                end

              {error.condition.ast, message_spec}
            end)

          %{
            type: :form_field_errors,
            name: field_name,
            depends_on: [params_dep, server_errors_dep | custom_error_deps],
            async: false,
            reads: [],
            optimistic: true,
            params_dep: params_dep,
            server_errors_dep: server_errors_dep,
            field_str: to_string(validation.field),
            val_type: validation.type,
            required: validation.required,
            constraints: validation.constraints,
            ash_messages: build_ash_message_lookup(field_ash_validations),
            custom_error_specs: custom_error_specs
          }
        end)

      summary_specs =
        if validations != [] do
          field_names = Enum.map(validations, & &1.field)

          [
            %{
              type: :form_valid,
              name: :"#{form_name}_valid",
              depends_on: Enum.map(field_names, &:"#{form_name}_#{&1}_valid"),
              async: false,
              reads: [],
              optimistic: true,
              form_name: form_name,
              field_names: field_names
            },
            %{
              type: :form_errors,
              name: :"#{form_name}_errors",
              depends_on: Enum.map(field_names, &:"#{form_name}_#{&1}_errors"),
              async: false,
              reads: [],
              optimistic: true,
              form_name: form_name,
              field_names: field_names
            }
          ]
        else
          []
        end

      field_valid_specs ++ field_errors_specs ++ summary_specs
    else
      []
    end
  end

  defp build_ash_message_lookup(ash_validations) do
    Enum.reduce(ash_validations, %{}, fn spec, acc ->
      if spec.message do
        key =
          case spec.type do
            :required -> :required
            :min_length -> :min_length
            :max_length -> :max_length
            :length_between -> :length_between
            :exact_length -> :exact_length
            :match -> :match
            :numericality -> :numericality
            other -> other
          end

        Map.put(acc, key, spec.message)
      else
        acc
      end
    end)
  end

  # --- Calculation spec extraction ---

  defp extract_calc_specs(dsl_state, module) do
    calculations = Transformer.get_entities(dsl_state, [:calculations]) || []
    Enum.map(calculations, &extract_single_calc_spec(&1, module))
  end

  defp extract_single_calc_spec(calc, module) do
    deps = calc.rx.deps
    ast = calc.rx.ast
    normalized_deps = Enum.map(deps, &normalize_dep/1) |> Enum.uniq()
    declared_optimistic = Map.get(calc, :optimistic, true)
    is_async = Map.get(calc, :async, false)

    is_optimistic =
      cond do
        is_async -> false
        not declared_optimistic -> false
        true -> Lavash.Rx.Transpiler.transpilable?(ast)
      end

    %{
      type: :calculation,
      name: calc.name,
      depends_on: normalized_deps,
      async: is_async,
      reads: Map.get(calc, :reads, []),
      optimistic: is_optimistic,
      ast: ast,
      module: module
    }
  end

  defp normalize_dep({:path, root, _path}), do: root
  defp normalize_dep(atom) when is_atom(atom), do: atom

  # ============================================================
  # Runtime: convert persisted specs into Derived.Field structs
  # Called once per module by Dsl.Graph.compiled_graph, cached in persistent_term.
  # ============================================================

  @doc false
  def build_fields(module) do
    specs = Spark.Dsl.Extension.get_persisted(module, :lavash_field_specs) || []
    Enum.map(specs, &spec_to_field(&1, module))
  end

  defp spec_to_field(%{type: :read_by_id} = spec, _module) do
    resource = spec.resource
    action = spec.action
    id_dep = spec.id_dep

    %Lavash.Derived.Field{
      name: spec.name,
      depends_on: spec.depends_on,
      async: spec.async,
      reads: spec.reads,
      compute: fn deps ->
        id = Map.get(deps, id_dep)
        actor = Map.get(deps, :__actor__)

        case id do
          nil -> nil
          id -> get_record_by_id(resource, id, action, actor)
        end
      end
    }
  end

  defp spec_to_field(%{type: :read_by_id_fn} = spec, module) do
    resource = spec.resource
    action = spec.action
    # Look up the id function from the original entity
    read = Enum.find(module.__lavash__(:reads), &(&1.name == spec.name))
    id_fun = read.id

    %Lavash.Derived.Field{
      name: spec.name,
      depends_on: spec.depends_on,
      async: spec.async,
      reads: spec.reads,
      compute: fn deps ->
        state = Map.get(deps, :__all_state__, deps)
        actor = Map.get(deps, :__actor__)
        id = id_fun.(state)

        case id do
          nil -> nil
          id -> get_record_by_id(resource, id, action, actor)
        end
      end
    }
  end

  defp spec_to_field(%{type: :read_query} = spec, module) do
    resource = spec.resource
    action_name = spec.action_name
    action_type = spec.action_type
    as_options = spec.as_options

    # Rebuild arg_mapping with actual transform fns from entities
    arg_mapping =
      if Enum.any?(spec.arg_mapping, fn {_, _, has_transform} -> has_transform end) do
        read = Enum.find(module.__lavash__(:reads), &(&1.name == spec.name))
        overrides = (read.arguments || []) |> Map.new(&{&1.name, &1})

        Enum.map(spec.arg_mapping, fn {arg_name, source_field, has_transform} ->
          transform = if has_transform, do: overrides[arg_name].transform
          {arg_name, source_field, transform}
        end)
      else
        Enum.map(spec.arg_mapping, fn {arg_name, source_field, _} ->
          {arg_name, source_field, nil}
        end)
      end

    %Lavash.Derived.Field{
      name: spec.name,
      depends_on: spec.depends_on,
      async: spec.async,
      reads: spec.reads,
      compute: fn deps ->
        actor = Map.get(deps, :__actor__)

        args =
          Enum.reduce(arg_mapping, %{}, fn {arg_name, source_field, transform}, acc ->
            value = Map.get(deps, source_field)
            value = if transform, do: transform.(value), else: value
            Map.put(acc, arg_name, value)
          end)

        records =
          case action_type do
            :read ->
              query = Ash.Query.for_read(resource, action_name, args)

              case Ash.read(query, actor: actor) do
                {:ok, records} -> records
                {:error, error} -> raise error
              end

            :action ->
              input = Ash.ActionInput.for_action(resource, action_name, args)

              case Ash.run_action(input, actor: actor) do
                {:ok, result} -> result
                {:error, error} -> raise error
              end

            _ ->
              raise "Unsupported action type #{action_type} for read DSL entity"
          end

        if as_options do
          label_field = Keyword.get(as_options, :label)
          value_field = Keyword.get(as_options, :value, :id)

          Enum.map(records, fn record ->
            {Map.get(record, label_field), Map.get(record, value_field)}
          end)
        else
          records
        end
      end
    }
  end

  defp spec_to_field(%{type: :form} = spec, _module) do
    resource = spec.resource
    data_dep = spec.data_dep
    params_dep = spec.params_dep
    create_action = spec.create
    update_action = spec.update
    form_name = spec.form_name_str

    %Lavash.Derived.Field{
      name: spec.name,
      depends_on: spec.depends_on,
      async: false,
      reads: spec.reads,
      compute: fn deps ->
        params = Map.get(deps, params_dep, %{})
        data = if data_dep, do: Map.get(deps, data_dep), else: nil

        Lavash.Form.for_resource(resource, data, params,
          create: create_action,
          update: update_action,
          as: form_name
        )
      end
    }
  end

  defp spec_to_field(%{type: :form_field_valid} = spec, _module) do
    params_dep = spec.params_dep
    field_str = spec.field_str
    val_type = spec.val_type
    required = spec.required
    constraints = spec.constraints

    %Lavash.Derived.Field{
      name: spec.name,
      depends_on: spec.depends_on,
      async: false,
      optimistic: true,
      compute: fn deps ->
        params = Map.get(deps, params_dep, %{})
        value = Map.get(params, field_str)

        present =
          if required do
            not is_nil(value) and String.length(String.trim(value || "")) > 0
          else
            true
          end

        constraints_valid =
          case val_type do
            :string -> check_string_constraints(value, constraints)
            :integer -> check_integer_constraints(value, constraints)
            _ -> true
          end

        present and constraints_valid
      end
    }
  end

  defp spec_to_field(%{type: :form_field_errors} = spec, module) do
    params_dep = spec.params_dep
    server_errors_dep = spec.server_errors_dep
    field_str = spec.field_str
    val_type = spec.val_type
    required = spec.required
    constraints = spec.constraints
    ash_messages = spec.ash_messages
    custom_error_specs = spec.custom_error_specs

    %Lavash.Derived.Field{
      name: spec.name,
      depends_on: spec.depends_on,
      async: false,
      optimistic: true,
      compute: fn deps ->
        params = Map.get(deps, params_dep, %{})
        value = Map.get(params, field_str)

        is_empty = is_nil(value) or String.length(String.trim(to_string(value))) == 0

        errors = []

        errors =
          if required and is_empty do
            msg =
              Map.get(ash_messages, :required) ||
                Lavash.Form.ConstraintTranspiler.error_message(:required, nil)

            [msg | errors]
          else
            errors
          end

        errors =
          if is_empty do
            errors
          else
            errors ++ collect_constraint_errors(val_type, value, constraints, ash_messages)
          end

        custom_error_messages =
          Enum.flat_map(custom_error_specs, fn {condition_ast, message_spec} ->
            condition_fun = Lavash.Rx.Cache.compile_rx(module, condition_ast)

            if condition_fun.(deps) do
              message =
                case message_spec do
                  {:static, msg} ->
                    msg

                  {:dynamic, msg_ast} ->
                    Lavash.Rx.Cache.compile_rx(module, msg_ast).(deps)
                end

              [message]
            else
              []
            end
          end)

        server_errors_map = Map.get(deps, server_errors_dep, %{})
        server_errors = Map.get(server_errors_map, field_str, [])

        client_errors = Enum.reverse(errors) ++ custom_error_messages
        Enum.uniq(client_errors ++ server_errors)
      end
    }
  end

  defp spec_to_field(%{type: :form_valid} = spec, _module) do
    form_name = spec.form_name
    field_names = spec.field_names

    %Lavash.Derived.Field{
      name: spec.name,
      depends_on: spec.depends_on,
      async: false,
      optimistic: true,
      compute: fn deps ->
        field_names
        |> Enum.map(&deps[:"#{form_name}_#{&1}_valid"])
        |> Enum.all?()
      end
    }
  end

  defp spec_to_field(%{type: :form_errors} = spec, _module) do
    form_name = spec.form_name
    field_names = spec.field_names

    %Lavash.Derived.Field{
      name: spec.name,
      depends_on: spec.depends_on,
      async: false,
      optimistic: true,
      compute: fn deps ->
        field_names
        |> Enum.flat_map(&(deps[:"#{form_name}_#{&1}_errors"] || []))
      end
    }
  end

  defp spec_to_field(%{type: :calculation} = spec, _module) do
    ast = spec.ast
    module = spec.module

    # rewrite_string_calls and rewrite_local_calls are deterministic given the
    # module, so hoist them outside the per-fire closure. The cache then
    # compiles the rewritten AST once per module load.
    rewritten_ast =
      ast
      |> rewrite_string_calls()
      |> rewrite_local_calls(module)

    %Lavash.Derived.Field{
      name: spec.name,
      depends_on: spec.depends_on,
      async: spec.async,
      reads: spec.reads,
      optimistic: Map.get(spec, :optimistic, false),
      compute: fn deps_map ->
        Lavash.Rx.Cache.compile_rx(module, rewritten_ast).(deps_map)
      end
    }
  end

  # ============================================================
  # Shared helpers (used by both compile-time and runtime paths)
  # ============================================================

  defp extract_dependency(source) do
    case source do
      {:state, name} -> name
      {:result, name} -> name
      {:prop, name} -> name
      name when is_atom(name) -> name
      nil -> nil
    end
  end

  @doc false
  def get_record_by_id(resource, id, action, actor) do
    case Ash.get(resource, id, action: action, actor: actor, error?: false) do
      {:ok, record} -> record
      {:error, _err} -> nil
    end
  end

  defp rewrite_string_calls(ast) do
    Macro.prewalk(ast, fn
      {{:., meta1, [{:__aliases__, meta2, [:String]}, :chunk]}, meta3, args} ->
        {{:., meta1, [{:__aliases__, meta2, [:Lavash, :Rx, :String]}, :chunk]}, meta3, args}

      other ->
        other
    end)
  end

  defp rewrite_local_calls(ast, module) do
    module_functions =
      if function_exported?(module, :__info__, 1) do
        module.__info__(:functions) |> MapSet.new()
      else
        MapSet.new()
      end

    Macro.prewalk(ast, fn
      {func_name, meta, args} = node when is_atom(func_name) and is_list(args) ->
        arity = length(args)

        if MapSet.member?(module_functions, {func_name, arity}) do
          {{:., meta, [module, func_name]}, meta, args}
        else
          node
        end

      other ->
        other
    end)
  end

  defp collect_constraint_errors(:string, value, constraints, ash_messages) do
    value_str = to_string(value || "")
    len = value_str |> String.trim() |> String.length()

    []
    |> add_string_length_errors(len, constraints, ash_messages)
    |> add_string_match_errors(value_str, constraints, ash_messages)
  end

  defp collect_constraint_errors(:integer, value, constraints, ash_messages) do
    case Integer.parse(to_string(value || "0")) do
      {num, ""} ->
        errors = []

        errors =
          case Map.get(constraints, :min) do
            nil ->
              errors

            min ->
              if num < min do
                msg =
                  Map.get(ash_messages, :min) ||
                    Lavash.Form.ConstraintTranspiler.error_message(:min, min)

                [msg | errors]
              else
                errors
              end
          end

        errors =
          case Map.get(constraints, :max) do
            nil ->
              errors

            max ->
              if num > max do
                msg =
                  Map.get(ash_messages, :max) ||
                    Lavash.Form.ConstraintTranspiler.error_message(:max, max)

                [msg | errors]
              else
                errors
              end
          end

        errors

      _ ->
        msg =
          Map.get(ash_messages, :match) ||
            Lavash.Form.ConstraintTranspiler.error_message(:match, nil)

        [msg]
    end
  end

  defp collect_constraint_errors(_, _, _, _), do: []

  defp add_string_length_errors(errors, len, constraints, ash_messages) do
    min_c = Map.get(constraints, :min_length)
    max_c = Map.get(constraints, :max_length)

    cond do
      min_c && len < min_c ->
        msg =
          (max_c && Map.get(ash_messages, :length_between)) ||
            Map.get(ash_messages, :min_length) ||
            Lavash.Form.ConstraintTranspiler.error_message(:min_length, min_c)

        [msg | errors]

      max_c && len > max_c ->
        msg =
          (min_c && Map.get(ash_messages, :length_between)) ||
            Map.get(ash_messages, :max_length) ||
            Lavash.Form.ConstraintTranspiler.error_message(:max_length, max_c)

        [msg | errors]

      true ->
        errors
    end
  end

  defp add_string_match_errors(errors, value_str, constraints, ash_messages) do
    case Map.get(constraints, :match) do
      nil ->
        errors

      regex ->
        if String.match?(value_str, regex) do
          errors
        else
          msg =
            Map.get(ash_messages, :match) ||
              Lavash.Form.ConstraintTranspiler.error_message(:match, regex)

          [msg | errors]
        end
    end
  end

  defp check_string_constraints(value, constraints) do
    value = String.trim(value || "")

    min_ok =
      case Map.get(constraints, :min_length) do
        nil -> true
        min -> String.length(value) >= min
      end

    max_ok =
      case Map.get(constraints, :max_length) do
        nil -> true
        max -> String.length(value) <= max
      end

    match_ok =
      case Map.get(constraints, :match) do
        nil -> true
        regex -> String.match?(value, regex)
      end

    min_ok and max_ok and match_ok
  end

  defp check_integer_constraints(value, constraints) do
    case Integer.parse(value || "0") do
      {num, ""} ->
        min_ok =
          case Map.get(constraints, :min) do
            nil -> true
            min -> num >= min
          end

        max_ok =
          case Map.get(constraints, :max) do
            nil -> true
            max -> num <= max
          end

        min_ok and max_ok

      _ ->
        false
    end
  end
end
