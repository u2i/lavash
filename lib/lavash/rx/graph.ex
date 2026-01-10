defmodule Lavash.Rx.Graph do
  @moduledoc """
  Dependency graph for reactive state computation.

  This module handles the server-side execution of the reactive graph,
  including:
  - Topological sorting of derived fields
  - Dirty tracking and invalidation
  - Incremental recomputation
  - Async task management
  - Automatic propagation of special states (:loading, :error, nil)

  The graph is built from DSL declarations (state, derive, calculate, read, form)
  and maintains dependencies between fields. When a source field changes, all
  transitively affected fields are recomputed in topological order.

  See also `Lavash.Rx` for the reactive expression macro that captures
  dependencies at compile time.
  """

  alias Lavash.Socket, as: LSocket
  alias Phoenix.LiveView.AsyncResult

  def recompute_all(socket, module) do
    all_fields = collect_all_fields(module)
    sorted = topological_sort(all_fields)

    Enum.reduce(sorted, socket, fn field, sock ->
      compute_field(sock, module, field)
    end)
  end

  # Collect all derived-like fields from different DSL sections
  defp collect_all_fields(module) do
    derived_fields = module.__lavash__(:derived_fields)
    read_fields = expand_reads(module)
    form_fields = expand_forms(module)
    calculation_fields = expand_calculations(module)
    derived_fields ++ read_fields ++ form_fields ++ calculation_fields
  end

  # Expand calculate entities into derived-like field structs
  # Handles both legacy 4-tuple and new 7-tuple formats
  defp expand_calculations(module) do
    calculations =
      if function_exported?(module, :__lavash_calculations__, 0) do
        module.__lavash_calculations__()
      else
        []
      end

    Enum.map(calculations, fn calc ->
      # Normalize to 7-tuple format for consistency
      {name, _source, ast, deps, _optimistic, is_async, reads} =
        case calc do
          {name, source, ast, deps} ->
            {name, source, ast, deps, true, false, []}

          {name, source, ast, deps, opt, async, reads} ->
            {name, source, ast, deps, opt, async, reads}
        end

      # Normalize path deps to root field names for dependency tracking
      # {:path, :params, ["name"]} -> :params
      normalized_deps = Enum.map(deps, &normalize_dep/1) |> Enum.uniq()

      %Lavash.Derived.Field{
        name: name,
        depends_on: normalized_deps,
        async: is_async,
        reads: reads,
        optimistic: true,
        compute: fn deps_map ->
          # Build state map from deps_map for AST evaluation
          # Create an env with the module so defrx functions are accessible
          eval_env = %{__ENV__ | module: module}

          # Rewrite String.chunk calls to Lavash.Rx.String.chunk for Elixir-side evaluation
          # (String.chunk doesn't support integer size in stdlib)
          rewritten_ast = rewrite_string_calls(ast)

          {result, _binding} = Code.eval_quoted(rewritten_ast, [state: deps_map], eval_env)
          result
        end
      }
    end)
  end

  # Normalize a dependency - extract root field from path deps
  defp normalize_dep({:path, root, _path}), do: root
  defp normalize_dep(atom) when is_atom(atom), do: atom

  # Rewrite String module calls to Lavash.Rx.String for Elixir-side evaluation
  # This is needed because the transpiler emits JS equivalents, but Elixir's
  # String module doesn't have all the same functions (e.g., String.chunk/2 with integer size)
  defp rewrite_string_calls(ast) do
    Macro.prewalk(ast, fn
      # String.chunk -> Lavash.Rx.String.chunk
      {{:., meta1, [{:__aliases__, meta2, [:String]}, :chunk]}, meta3, args} ->
        {{:., meta1, [{:__aliases__, meta2, [:Lavash, :Rx, :String]}, :chunk]}, meta3, args}

      other ->
        other
    end)
  end

  # Expand read entities into derived-like field structs
  defp expand_reads(module) do
    reads = module.__lavash__(:reads)
    states = module.__lavash__(:states)
    state_names = MapSet.new(states, & &1.name)

    Enum.map(reads, fn read ->
      if read.id do
        # Mode 1: Get by ID (single record)
        expand_read_by_id(read)
      else
        # Mode 2: Query with auto-mapped arguments
        expand_read_query(read, state_names)
      end
    end)
  end

  # Get-by-ID mode: load a single record
  defp expand_read_by_id(read) do
    id_dep = extract_dependency(read.id)
    resource = read.resource
    action = read.action || :read
    is_async = read.async != false

    %Lavash.Derived.Field{
      name: read.name,
      depends_on: [id_dep, :__actor__],
      async: is_async,
      compute: fn deps ->
        id = Map.get(deps, id_dep)
        actor = Map.get(deps, :__actor__)

        case id do
          nil ->
            nil

          id ->
            case Ash.get(resource, id, action: action, actor: actor) do
              {:ok, record} -> record
              {:error, %Ash.Error.Query.NotFound{}} -> nil
              {:error, error} -> raise error
            end
        end
      end
    }
  end

  # Query mode: run an action with auto-mapped arguments
  defp expand_read_query(read, state_names) do
    resource = read.resource
    action_name = read.action || :read
    is_async = read.async != false
    as_options = read.as_options

    # Get the action from the resource to determine its type
    action = Ash.Resource.Info.action(resource, action_name)
    action_type = if action, do: action.type, else: :read
    action_args = if action, do: action.arguments, else: []

    # Build argument overrides map from DSL entities
    arg_overrides =
      (read.arguments || [])
      |> Enum.map(fn arg -> {arg.name, arg} end)
      |> Map.new()

    # Build the dependency list and arg mapping
    # For each action argument, find the source (state field or override)
    {depends_on, arg_mapping} =
      Enum.reduce(action_args, {[], []}, fn action_arg, {deps, mapping} ->
        arg_name = action_arg.name

        case Map.get(arg_overrides, arg_name) do
          nil ->
            # No override - auto-map from state field with same name if it exists
            if MapSet.member?(state_names, arg_name) do
              {[arg_name | deps], [{arg_name, arg_name, nil} | mapping]}
            else
              # No matching state field - skip this arg (will be nil)
              {deps, mapping}
            end

          %{source: source, transform: transform} ->
            # Explicit override
            source_field = if source, do: extract_dependency(source), else: arg_name
            {[source_field | deps], [{arg_name, source_field, transform} | mapping]}
        end
      end)

    # Add :__actor__ to dependencies for authorization
    depends_on = (Enum.reverse(depends_on) ++ [:__actor__]) |> Enum.uniq()
    arg_mapping = Enum.reverse(arg_mapping)

    %Lavash.Derived.Field{
      name: read.name,
      depends_on: depends_on,
      async: is_async,
      reads: [resource],
      compute: fn deps ->
        actor = Map.get(deps, :__actor__)

        # Build the args map
        args =
          Enum.reduce(arg_mapping, %{}, fn {arg_name, source_field, transform}, acc ->
            value = Map.get(deps, source_field)
            value = if transform, do: transform.(value), else: value
            Map.put(acc, arg_name, value)
          end)

        # Use the appropriate Ash function based on action type
        records =
          case action_type do
            :read ->
              # Read action - use Ash.Query.for_read + Ash.read
              query = Ash.Query.for_read(resource, action_name, args)

              case Ash.read(query, actor: actor) do
                {:ok, records} -> records
                {:error, error} -> raise error
              end

            :action ->
              # Generic action - use Ash.ActionInput.for_action + Ash.run_action
              input = Ash.ActionInput.for_action(resource, action_name, args)

              case Ash.run_action(input, actor: actor) do
                {:ok, result} -> result
                {:error, error} -> raise error
              end

            _ ->
              raise "Unsupported action type #{action_type} for read DSL entity"
          end

        # Apply as_options transform if specified
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

  # Expand form entities into derived-like field structs
  # Also generates validation calculations from Ash resource constraints
  defp expand_forms(module) do
    forms = module.__lavash__(:forms)

    Enum.flat_map(forms, fn form ->
      # Extract dependencies from data and params options
      data_dep = extract_dependency(form.data)

      # Params defaults to implicit :name_params if not specified
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
      form_name = to_string(form.name)

      # The form field itself
      form_field = %Lavash.Derived.Field{
        name: form.name,
        depends_on: depends_on,
        async: false,
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

      # Generate validation fields from resource constraints
      validation_fields = expand_form_validations(module, form, params_dep)

      [form_field | validation_fields]
    end)
  end

  # Generate validation calculation fields from Ash resource constraints
  defp expand_form_validations(module, form, params_dep) do
    resource = form.resource
    form_name = form.name
    create_action = form.create

    # Get any extend_errors declarations for this form
    extend_errors_map = get_extend_errors_map(module)

    # Check if resource is available at compile time
    # (might not be if it's in a different app that isn't compiled yet)
    if Code.ensure_loaded?(resource) and
         function_exported?(resource, :spark_dsl_config, 0) do
      # Get constraint-based validations (from attribute type constraints)
      validations = Lavash.Form.ConstraintTranspiler.extract_validations(resource)

      # Get Ash validations with custom messages (from validations do block)
      # These override the default constraint messages when available
      ash_validations = Lavash.Form.ValidationTranspiler.extract_validations_for_action(resource, create_action)

      # Generate a _valid field for each attribute
      field_valid_fields =
        Enum.map(validations, fn validation ->
          field_name = :"#{form_name}_#{validation.field}_valid"

          %Lavash.Derived.Field{
            name: field_name,
            depends_on: [params_dep],
            async: false,
            optimistic: true,
            compute: build_validation_compute(validation, params_dep)
          }
        end)

      # Generate a _errors field for each attribute
      field_errors_fields =
        Enum.map(validations, fn validation ->
          field_name = :"#{form_name}_#{validation.field}_errors"

          # Check if there are custom errors to extend this field
          custom_errors = Map.get(extend_errors_map, field_name, [])

          # Get Ash validation messages for this field (overrides constraint messages)
          field_ash_validations = Map.get(ash_validations, validation.field, [])

          # Extract dependencies from custom error conditions
          custom_error_deps =
            Enum.flat_map(custom_errors, fn error ->
              case error.condition do
                %Lavash.Rx{deps: deps} when is_list(deps) ->
                  # Convert path dependencies to just the root variable name
                  Enum.map(deps, fn
                    {:path, var_name, _path} -> var_name
                    dep when is_atom(dep) -> dep
                  end)

                _ ->
                  []
              end
            end)
            |> Enum.uniq()

          %Lavash.Derived.Field{
            name: field_name,
            depends_on: [params_dep | custom_error_deps],
            async: false,
            optimistic: true,
            compute: build_errors_compute(validation, params_dep, custom_errors, field_ash_validations)
          }
        end)

      # Generate a _show_errors field for each attribute
      # These are always false on server - JS manages them based on touched/submitted state
      field_show_errors_fields =
        Enum.map(validations, fn validation ->
          field_name = :"#{form_name}_#{validation.field}_show_errors"

          %Lavash.Derived.Field{
            name: field_name,
            depends_on: [],
            async: false,
            optimistic: true,
            compute: fn _deps -> false end
          }
        end)

      # Generate an overall _valid field that combines all field validations
      if length(validations) > 0 do
        field_names = Enum.map(validations, & &1.field)

        form_valid_field = %Lavash.Derived.Field{
          name: :"#{form_name}_valid",
          depends_on: Enum.map(field_names, &:"#{form_name}_#{&1}_valid"),
          async: false,
          optimistic: true,
          compute: fn deps ->
            field_names
            |> Enum.map(&deps[:"#{form_name}_#{&1}_valid"])
            |> Enum.all?()
          end
        }

        # Generate an overall _errors field that combines all field errors
        form_errors_field = %Lavash.Derived.Field{
          name: :"#{form_name}_errors",
          depends_on: Enum.map(field_names, &:"#{form_name}_#{&1}_errors"),
          async: false,
          optimistic: true,
          compute: fn deps ->
            field_names
            |> Enum.flat_map(&(deps[:"#{form_name}_#{&1}_errors"] || []))
          end
        }

        field_valid_fields ++ field_errors_fields ++ field_show_errors_fields ++ [form_valid_field, form_errors_field]
      else
        field_valid_fields ++ field_errors_fields ++ field_show_errors_fields
      end
    else
      []
    end
  end

  # Build a compute function for a validation field
  defp build_validation_compute(validation, params_dep) do
    field = validation.field
    field_str = to_string(field)
    type = validation.type
    required = validation.required
    constraints = validation.constraints

    fn deps ->
      params = Map.get(deps, params_dep, %{})
      value = Map.get(params, field_str)

      # Check required
      present =
        if required do
          not is_nil(value) and String.length(String.trim(value || "")) > 0
        else
          true
        end

      # Check type-specific constraints
      constraints_valid =
        case type do
          :string ->
            check_string_constraints(value, constraints)

          :integer ->
            check_integer_constraints(value, constraints)

          _ ->
            true
        end

      present and constraints_valid
    end
  end

  # Build a compute function for an errors field
  # ash_validations: list of validation specs from ValidationTranspiler (with custom messages)
  defp build_errors_compute(validation, params_dep, custom_errors \\ [], ash_validations \\ []) do
    field = validation.field
    field_str = to_string(field)
    type = validation.type
    required = validation.required
    constraints = validation.constraints

    # Build a message lookup from Ash validations
    # Maps validation type to custom message
    ash_messages = build_ash_message_lookup(ash_validations)

    # Store custom error conditions (Lavash.Rx structs) and messages
    # Messages can be static strings or dynamic Lavash.Rx structs
    # We evaluate the AST at runtime like calculate does
    custom_error_specs =
      Enum.map(custom_errors, fn error ->
        message_spec = case error.message do
          %Lavash.Rx{ast: ast} -> {:dynamic, ast}
          static_string when is_binary(static_string) -> {:static, static_string}
        end
        {error.condition.ast, message_spec}
      end)

    fn deps ->
      params = Map.get(deps, params_dep, %{})
      value = Map.get(params, field_str)

      # Don't show errors if field is empty (unless required)
      is_empty = is_nil(value) or String.length(String.trim(to_string(value))) == 0

      errors = []

      # Required check - use Ash message if available
      errors =
        if required and is_empty do
          msg = Map.get(ash_messages, :required) ||
                Lavash.Form.ConstraintTranspiler.error_message(:required, nil)
          [msg | errors]
        else
          errors
        end

      # Only check other constraints if field is not empty
      errors =
        if not is_empty do
          errors ++ collect_constraint_errors(type, value, constraints, ash_messages)
        else
          errors
        end

      # Add custom errors where condition evaluates to true
      # The condition should return true when the error should be shown (i.e., field is invalid)
      custom_error_messages =
        Enum.flat_map(custom_error_specs, fn {condition_ast, message_spec} ->
          # Evaluate the condition AST with state bound to deps
          {result, _binding} = Code.eval_quoted(condition_ast, [state: deps], __ENV__)
          if result do
            # Evaluate the message - static string or dynamic expression
            message = case message_spec do
              {:static, msg} -> msg
              {:dynamic, msg_ast} ->
                {msg_result, _} = Code.eval_quoted(msg_ast, [state: deps], __ENV__)
                msg_result
            end
            [message]
          else
            []
          end
        end)

      Enum.reverse(errors) ++ custom_error_messages
    end
  end

  # Build a lookup map from Ash validation type to custom message
  defp build_ash_message_lookup(ash_validations) do
    Enum.reduce(ash_validations, %{}, fn spec, acc ->
      if spec.message do
        # Map validation types to lookup keys
        key = case spec.type do
          :required -> :required
          :min_length -> :min_length
          :max_length -> :max_length
          :length_between -> :length_between  # has both min and max
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

  defp collect_constraint_errors(:string, value, constraints, ash_messages) do
    value_str = to_string(value || "")
    trimmed = String.trim(value_str)
    len = String.length(trimmed)
    errors = []

    min_constraint = Map.get(constraints, :min_length)
    max_constraint = Map.get(constraints, :max_length)

    # Check if we have both min and max constraints - use length_between message if available
    errors =
      cond do
        min_constraint && max_constraint && len < min_constraint ->
          # Check for length_between message first, then fall back to min_length
          msg = Map.get(ash_messages, :length_between) ||
                Map.get(ash_messages, :min_length) ||
                Lavash.Form.ConstraintTranspiler.error_message(:min_length, min_constraint)
          [msg | errors]

        min_constraint && max_constraint && len > max_constraint ->
          msg = Map.get(ash_messages, :length_between) ||
                Map.get(ash_messages, :max_length) ||
                Lavash.Form.ConstraintTranspiler.error_message(:max_length, max_constraint)
          [msg | errors]

        min_constraint && !max_constraint && len < min_constraint ->
          msg = Map.get(ash_messages, :min_length) ||
                Lavash.Form.ConstraintTranspiler.error_message(:min_length, min_constraint)
          [msg | errors]

        max_constraint && !min_constraint && len > max_constraint ->
          msg = Map.get(ash_messages, :max_length) ||
                Lavash.Form.ConstraintTranspiler.error_message(:max_length, max_constraint)
          [msg | errors]

        true ->
          errors
      end

    errors =
      case Map.get(constraints, :match) do
        nil -> errors
        regex ->
          if String.match?(value_str, regex) do
            errors
          else
            msg = Map.get(ash_messages, :match) ||
                  Lavash.Form.ConstraintTranspiler.error_message(:match, regex)
            [msg | errors]
          end
      end

    errors
  end

  defp collect_constraint_errors(:integer, value, constraints, ash_messages) do
    case Integer.parse(to_string(value || "0")) do
      {num, ""} ->
        errors = []

        errors =
          case Map.get(constraints, :min) do
            nil -> errors
            min ->
              if num < min do
                msg = Map.get(ash_messages, :min) ||
                      Lavash.Form.ConstraintTranspiler.error_message(:min, min)
                [msg | errors]
              else
                errors
              end
          end

        errors =
          case Map.get(constraints, :max) do
            nil -> errors
            max ->
              if num > max do
                msg = Map.get(ash_messages, :max) ||
                      Lavash.Form.ConstraintTranspiler.error_message(:max, max)
                [msg | errors]
              else
                errors
              end
          end

        errors

      _ ->
        msg = Map.get(ash_messages, :match) ||
              Lavash.Form.ConstraintTranspiler.error_message(:match, nil)
        [msg]
    end
  end

  defp collect_constraint_errors(_, _, _, _), do: []

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

  # Extract the field name from state(:x), result(:x), or prop(:x) tuples
  defp extract_dependency(source) do
    case source do
      {:state, name} -> name
      {:result, name} -> name
      {:prop, name} -> name
      name when is_atom(name) -> name
      nil -> nil
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

  def recompute_dirty(socket, module) do
    dirty = LSocket.dirty(socket)

    if MapSet.size(dirty) == 0 do
      socket
    else
      all_fields = collect_all_fields(module)

      # Find all derived fields affected by dirty state, including transitive dependencies
      # include_dirty: true means also include fields that are directly marked dirty
      affected = find_affected_derived(all_fields, dirty, include_dirty: true)
      sorted = topological_sort(affected)

      socket = LSocket.clear_dirty(socket)

      Enum.reduce(sorted, socket, fn field, sock ->
        compute_field(sock, module, field)
      end)
    end
  end

  defp find_affected_derived(derived_fields, dirty, opts \\ []) do
    include_dirty = Keyword.get(opts, :include_dirty, false)

    # Start with fields whose dependencies are dirty
    # Optionally also include fields that are directly marked dirty
    directly_affected =
      derived_fields
      |> Enum.filter(fn field ->
        deps_dirty = Enum.any?(field.depends_on, &MapSet.member?(dirty, &1))
        self_dirty = include_dirty and MapSet.member?(dirty, field.name)
        deps_dirty or self_dirty
      end)
      |> MapSet.new(& &1.name)

    # Transitively find all derived fields that depend on affected fields
    all_affected = expand_affected(directly_affected, derived_fields)

    # Return the actual field structs
    Enum.filter(derived_fields, fn f -> MapSet.member?(all_affected, f.name) end)
  end

  defp expand_affected(affected, all_fields) do
    # Find fields that depend on any affected field
    newly_affected =
      all_fields
      |> Enum.filter(fn field ->
        not MapSet.member?(affected, field.name) and
          Enum.any?(field.depends_on, &MapSet.member?(affected, &1))
      end)
      |> MapSet.new(& &1.name)

    if MapSet.size(newly_affected) == 0 do
      # No more fields to add
      affected
    else
      # Recurse with expanded set
      expand_affected(MapSet.union(affected, newly_affected), all_fields)
    end
  end

  def recompute_dependents(socket, module, changed_field) do
    all_fields = collect_all_fields(module)

    # Find all derived fields affected by the changed field, including transitive dependencies
    affected = find_affected_derived(all_fields, MapSet.new([changed_field]))
    sorted = topological_sort(affected)

    Enum.reduce(sorted, socket, fn field, sock ->
      compute_field(sock, module, field)
    end)
  end

  defp compute_field(socket, _module, field) do
    deps = build_deps_map(socket, field.depends_on)

    # Check for propagating states in dependencies
    case check_deps_state(deps) do
      {:propagate, state} ->
        # Propagate the special state without running compute
        LSocket.put_derived(socket, field.name, state)

      {:ready, had_async} ->
        # All deps are ready - run the compute function
        # had_async tells us if any dep was an AsyncResult (so we should wrap output)
        run_compute(socket, field, deps, had_async)
    end
  end

  defp check_deps_state(deps) do
    # Check for states that should propagate through the chain
    # Also track if any deps were AsyncResult (even if ok) so we can wrap output
    Enum.reduce_while(deps, {:ready, false}, fn {_key, value}, {_status, had_async} ->
      case value do
        %AsyncResult{loading: loading} when loading != nil ->
          {:halt, {:propagate, AsyncResult.loading()}}

        %AsyncResult{failed: failed} when failed != nil ->
          {:halt, {:propagate, value}}

        %AsyncResult{ok?: true} ->
          # Dep was async but is now ok - track this
          {:cont, {:ready, true}}

        _ ->
          {:cont, {:ready, had_async}}
      end
    end)
  end

  defp run_compute(socket, field, deps, had_async) do
    # Unwrap Async structs so compute functions receive plain values
    unwrapped_deps = unwrap_async_for_compute(deps)

    if field.async do
      # Start async task
      self_pid = self()

      # Check if we're in a component context (has component_id in lavash state)
      component_id = LSocket.get(socket, :component_id)

      if component_id do
        # For components, we need to use send_update to deliver async results
        # Get the component module from socket assigns
        component_module = socket.assigns[:__component_module__]

        Task.start(fn ->
          result = field.compute.(unwrapped_deps)
          # Send update to the component via the LiveView process
          send(
            self_pid,
            {:lavash_component_async, component_module, component_id, field.name, result}
          )
        end)
      else
        # For LiveViews, use the standard approach
        Task.start(fn ->
          result = field.compute.(unwrapped_deps)
          send(self_pid, {:lavash_async, field.name, result})
        end)
      end

      LSocket.put_derived(socket, field.name, AsyncResult.loading())
    else
      # Non-async: store result, auto-wrapping changesets
      result = field.compute.(unwrapped_deps)
      wrapped = maybe_wrap_changeset(result)

      # If any dependency was async, wrap the result in AsyncResult.ok()
      # so downstream consumers (<.async_result>) can use it
      final =
        if had_async do
          AsyncResult.ok(wrapped)
        else
          wrapped
        end

      LSocket.put_derived(socket, field.name, final)
    end
  end

  # Auto-wrap Ash.Changeset to provide both form rendering and submission
  defp maybe_wrap_changeset(%Ash.Changeset{} = changeset) do
    Lavash.Form.wrap(changeset)
  end

  defp maybe_wrap_changeset(other), do: other

  defp build_deps_map(socket, deps) do
    state = LSocket.state(socket)
    derived = LSocket.derived(socket)

    Enum.reduce(deps, %{}, fn dep, acc ->
      value =
        cond do
          # Special reserved key for actor - reads from socket assigns
          dep == :__actor__ ->
            socket.assigns[:current_user]

          Map.has_key?(state, dep) ->
            Map.get(state, dep)

          Map.has_key?(derived, dep) ->
            # Pass through Async structs - check_deps_state will handle propagation
            # and unwrap_async_for_compute will extract the result when ready
            Map.get(derived, dep)

          true ->
            nil
        end

      Map.put(acc, dep, value)
    end)
  end

  # Unwrap Async structs for compute functions once check_deps_state returns :ready
  defp unwrap_async_for_compute(deps) do
    Map.new(deps, fn {key, value} ->
      unwrapped =
        case value do
          %AsyncResult{ok?: true, result: result} -> result
          other -> other
        end

      {key, unwrapped}
    end)
  end

  defp topological_sort(fields) do
    # Simple topological sort based on depends_on
    # For now, just sort by number of dependencies (crude but works for simple cases)
    Enum.sort_by(fields, fn field ->
      count_depth(field, fields, %{})
    end)
  end

  defp count_depth(field, all_fields, seen) do
    if Map.has_key?(seen, field.name) do
      0
    else
      deps = field.depends_on

      dep_depths =
        Enum.map(deps, fn dep ->
          case Enum.find(all_fields, &(&1.name == dep)) do
            nil -> 0
            dep_field -> 1 + count_depth(dep_field, all_fields, Map.put(seen, field.name, true))
          end
        end)

      case dep_depths do
        [] -> 0
        depths -> Enum.max(depths)
      end
    end
  end

  @doc """
  Returns field names that depend on reads/forms of a given resource.
  Used for resource-centric invalidation when a child component mutates a resource.
  """
  def fields_for_resource(module, resource) do
    # Get reads that use this resource
    read_fields =
      module.__lavash__(:reads)
      |> Enum.filter(&(&1.resource == resource))
      |> Enum.map(& &1.name)

    # Get forms that use this resource
    form_fields =
      module.__lavash__(:forms)
      |> Enum.filter(&(&1.resource == resource))
      |> Enum.map(& &1.name)

    # Get derived fields that declare this resource in their reads list
    derived_fields =
      module.__lavash__(:derived_fields)
      |> Enum.filter(fn field ->
        resource in (field.reads || [])
      end)
      |> Enum.map(& &1.name)

    read_fields ++ form_fields ++ derived_fields
  end
end
