defmodule Lavash.Form.ValidationJs do
  @moduledoc """
  Generates JavaScript for form field validation and error checking.

  Shared by both `ColocatedTransformer` (compile-time) and `JsGenerator` (runtime).
  Handles constraint-based validation (required, min_length, max, match, etc.)
  and custom error checks from `extend_errors`.
  """

  @doc """
  Generate JS for a field validation derive (returns boolean).

  Options:
  - `name` - derive name (e.g., `:checkout_name_valid`)
  - `params_field` - the params state field (e.g., `:checkout_params`)
  - `validation` - validation spec from `ConstraintTranspiler`
  - `skip_constraints` - whether to skip all constraint checks
  """
  def generate_field_validation_js(name, params_field, validation, skip_constraints) do
    field_str = to_string(validation.field)
    required = validation.required
    type = validation.type
    constraints = validation.constraints

    value_expr = "state.#{params_field}?.[#{Jason.encode!(field_str)}]"

    checks =
      if skip_constraints do
        []
      else
        checks =
          if required do
            ["(#{value_expr} != null && String(#{value_expr}).trim().length > 0)"]
          else
            []
          end

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

  @doc """
  Generate JS for a combined form validation derive (ANDs all field validations).
  """
  def generate_combined_validation_js(name, form_name, field_names) do
    checks =
      Enum.map_join(field_names, " && ", fn field -> "state.#{form_name}_#{field}_valid" end)

    """
      #{name}(state) {
        return #{checks};
      }
    """
  end

  @doc """
  Generate JS for a field errors derive (returns array of error strings).

  Options:
  - `name` - derive name (e.g., `:checkout_name_errors`)
  - `params_field` - the params state field
  - `validation` - validation spec
  - `custom_errors` - list of custom error specs from `extend_errors`
  - `ash_validations` - Ash validation specs with custom messages
  - `skip_constraints` - whether to skip constraint checks
  - `opts` - keyword list:
    - `:expand_defrx` - function to expand defrx in source strings (optional)
    - `:server_errors_field` - field name for server errors merge (optional)
  """
  def generate_field_errors_js(
        name,
        params_field,
        validation,
        custom_errors,
        ash_validations,
        skip_constraints,
        opts \\ []
      ) do
    field = validation.field
    field_str = to_string(field)
    required = validation.required
    type = validation.type
    constraints = validation.constraints

    value_expr = "state.#{params_field}?.[#{Jason.encode!(field_str)}]"

    ash_messages = build_ash_message_lookup(ash_validations)

    error_checks =
      if skip_constraints do
        []
      else
        error_checks =
          if required do
            msg =
              Map.get(ash_messages, :required) ||
                Lavash.Form.ConstraintTranspiler.error_message(:required, nil)

            [
              "{check: #{value_expr} != null && String(#{value_expr}).trim().length > 0, msg: #{Jason.encode!(msg)}}"
            ]
          else
            []
          end

        case type do
          :string ->
            build_string_error_checks(value_expr, constraints, error_checks, ash_messages)

          :integer ->
            build_integer_error_checks(value_expr, constraints, error_checks, ash_messages)

          _ ->
            error_checks
        end
      end

    # Add custom error checks from extend_errors
    expand_defrx = Keyword.get(opts, :expand_defrx, &Function.identity/1)

    error_checks =
      Enum.reduce(custom_errors, error_checks, fn error, acc ->
        expanded_condition = expand_defrx.(error.condition.source)
        js_condition = Lavash.Rx.Transpiler.to_js(expanded_condition)

        msg_js =
          case error.message do
            %Lavash.Rx{source: source} ->
              expanded_msg = expand_defrx.(source)
              "(#{Lavash.Rx.Transpiler.to_js(expanded_msg)})"

            static_string when is_binary(static_string) ->
              Jason.encode!(static_string)
          end

        check = "{check: !(#{js_condition}), msg: #{msg_js}}"
        [check | acc]
      end)

    checks_array = "[" <> Enum.join(Enum.reverse(error_checks), ", ") <> "]"

    # Optional server errors merge
    server_errors_field = Keyword.get(opts, :server_errors_field)

    if server_errors_field do
      """
        #{name}(state) {
          const v = #{value_expr};
          const isEmpty = v == null || String(v).trim().length === 0;
          const checks = #{checks_array};
          const clientErrors = checks
            .filter(c => !c.check && (#{required} || !isEmpty))
            .map(c => c.msg);
          const serverErrors = state.#{server_errors_field}?.[#{Jason.encode!(field_str)}] || [];
          const merged = [...clientErrors];
          for (const e of serverErrors) { if (!merged.includes(e)) merged.push(e); }
          return merged;
        }
      """
    else
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
  end

  @doc """
  Generate JS for a combined form errors derive (concatenates all field error arrays).
  """
  def generate_combined_errors_js(name, form_name, field_names) do
    arrays =
      Enum.map_join(field_names, ", ", fn field ->
        "...(state.#{form_name}_#{field}_errors || [])"
      end)

    """
      #{name}(state) {
        return [#{arrays}];
      }
    """
  end

  # ============================================
  # Constraint checks (boolean, for _valid derives)
  # ============================================

  @doc false
  def build_string_constraint_checks(value_expr, constraints, checks) do
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

    case Map.get(constraints, :match) do
      nil ->
        checks

      regex ->
        pattern = Regex.source(regex)
        ["(#{Jason.encode!(pattern)}).match(#{value_expr} || '')" | checks]
    end
  end

  @doc false
  def build_integer_constraint_checks(value_expr, constraints, checks) do
    parsed = "parseInt(#{value_expr} || '0', 10)"

    checks =
      case Map.get(constraints, :min) do
        nil -> checks
        min -> ["(#{parsed} >= #{min})" | checks]
      end

    case Map.get(constraints, :max) do
      nil -> checks
      max -> ["(#{parsed} <= #{max})" | checks]
    end
  end

  # ============================================
  # Error checks (with messages, for _errors derives)
  # ============================================

  @doc false
  def build_string_error_checks(value_expr, constraints, checks, ash_messages) do
    checks =
      case Map.get(constraints, :min_length) do
        nil ->
          checks

        min ->
          msg =
            Map.get(ash_messages, :min_length) ||
              Map.get(ash_messages, :length_between) ||
              Lavash.Form.ConstraintTranspiler.error_message(:min_length, min)

          [
            "{check: String(#{value_expr} || '').trim().length >= #{min}, msg: #{Jason.encode!(msg)}}"
            | checks
          ]
      end

    checks =
      case Map.get(constraints, :max_length) do
        nil ->
          checks

        max ->
          msg =
            Map.get(ash_messages, :max_length) ||
              Map.get(ash_messages, :length_between) ||
              Lavash.Form.ConstraintTranspiler.error_message(:max_length, max)

          [
            "{check: String(#{value_expr} || '').trim().length <= #{max}, msg: #{Jason.encode!(msg)}}"
            | checks
          ]
      end

    case Map.get(constraints, :match) do
      nil ->
        checks

      regex ->
        pattern = Regex.source(regex)

        msg =
          Map.get(ash_messages, :match) ||
            Lavash.Form.ConstraintTranspiler.error_message(:match, regex)

        [
          "{check: new RegExp(#{Jason.encode!(pattern)}).test(#{value_expr} || ''), msg: #{Jason.encode!(msg)}}"
          | checks
        ]
    end
  end

  @doc false
  def build_integer_error_checks(value_expr, constraints, checks, ash_messages) do
    parsed = "parseInt(#{value_expr} || '0', 10)"

    checks =
      case Map.get(constraints, :min) do
        nil ->
          checks

        min ->
          msg =
            Map.get(ash_messages, :min) ||
              Map.get(ash_messages, :numericality) ||
              Lavash.Form.ConstraintTranspiler.error_message(:min, min)

          ["{check: #{parsed} >= #{min}, msg: #{Jason.encode!(msg)}}" | checks]
      end

    case Map.get(constraints, :max) do
      nil ->
        checks

      max ->
        msg =
          Map.get(ash_messages, :max) ||
            Map.get(ash_messages, :numericality) ||
            Lavash.Form.ConstraintTranspiler.error_message(:max, max)

        ["{check: #{parsed} <= #{max}, msg: #{Jason.encode!(msg)}}" | checks]
    end
  end

  @doc false
  def build_ash_message_lookup(ash_validations) do
    Enum.reduce(ash_validations, %{}, fn spec, acc ->
      if spec.message do
        message = Lavash.Form.ValidationTranspiler.get_message(spec)
        Map.put(acc, spec.type, message)
      else
        acc
      end
    end)
  end
end
