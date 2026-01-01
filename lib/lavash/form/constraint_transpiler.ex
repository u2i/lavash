defmodule Lavash.Form.ConstraintTranspiler do
  @moduledoc """
  Transpiles Ash resource constraints to rx() expressions for client-side validation.

  This allows form validation to be driven from a single source of truth (the Ash resource)
  while still providing instant client-side feedback.

  Supported constraints:
  - String: min_length, max_length, match (regex)
  - Integer: min, max
  - All types: allow_nil? (required fields)
  """

  @doc """
  Generates validation info for all attributes of a resource that have transpilable constraints.

  Returns a list of field validation specs that can be used to generate calculate declarations.
  """
  def extract_validations(resource) do
    attrs = Ash.Resource.Info.attributes(resource)

    attrs
    |> Enum.filter(&has_transpilable_constraints?/1)
    |> Enum.map(fn attr ->
      %{
        field: attr.name,
        type: normalize_type(attr.type),
        required: not attr.allow_nil?,
        constraints: extract_constraints(attr)
      }
    end)
  end

  @doc """
  Checks if an attribute has any constraints we can transpile to JS.
  """
  def has_transpilable_constraints?(attr) do
    # Skip id fields
    if attr.name == :id do
      false
    else
      has_type_constraints?(attr) or not attr.allow_nil?
    end
  end

  defp has_type_constraints?(attr) do
    constraints = attr.constraints || []

    Enum.any?(constraints, fn {key, _value} ->
      key in [:min_length, :max_length, :match, :min, :max]
    end)
  end

  defp normalize_type(type) do
    case type do
      Ash.Type.String -> :string
      Ash.Type.Integer -> :integer
      other when is_atom(other) -> other
      _ -> :unknown
    end
  end

  defp extract_constraints(attr) do
    constraints = attr.constraints || []

    constraints
    |> Enum.filter(fn {key, _} -> key in [:min_length, :max_length, :match, :min, :max] end)
    |> Enum.into(%{})
  end

  @doc """
  Generates an rx() expression AST for a field's validity check.

  The expression references @<params_field>["<field_name>"] for the value.
  """
  def build_valid_expression(validation, params_field) do
    field = validation.field
    field_str = to_string(field)

    # Build the base value access: @params_field["field"]
    value_access = quote do
      @unquote(Macro.var(params_field, nil))[unquote(field_str)]
    end

    # Build individual checks
    checks = []

    # Required check
    checks =
      if validation.required do
        check =
          quote do
            not is_nil(unquote(value_access)) and
              String.length(String.trim(unquote(value_access) || "")) > 0
          end

        [check | checks]
      else
        checks
      end

    # Type-specific constraints
    checks = checks ++ build_constraint_checks(validation, value_access)

    # Combine with `and`
    case checks do
      [] -> quote(do: true)
      [single] -> single
      multiple ->
        Enum.reduce(multiple, fn check, acc ->
          quote(do: unquote(acc) and unquote(check))
        end)
    end
  end

  defp build_constraint_checks(validation, value_access) do
    case validation.type do
      :string -> build_string_checks(validation.constraints, value_access)
      :integer -> build_integer_checks(validation.constraints, value_access)
      _ -> []
    end
  end

  defp build_string_checks(constraints, value_access) do
    checks = []

    # min_length
    checks =
      case Map.get(constraints, :min_length) do
        nil ->
          checks

        min ->
          check =
            quote do
              String.length(String.trim(unquote(value_access) || "")) >= unquote(min)
            end

          [check | checks]
      end

    # max_length
    checks =
      case Map.get(constraints, :max_length) do
        nil ->
          checks

        max ->
          check =
            quote do
              String.length(String.trim(unquote(value_access) || "")) <= unquote(max)
            end

          [check | checks]
      end

    # match (regex)
    checks =
      case Map.get(constraints, :match) do
        nil ->
          checks

        regex ->
          check =
            quote do
              String.match?(unquote(value_access) || "", unquote(Macro.escape(regex)))
            end

          [check | checks]
      end

    checks
  end

  defp build_integer_checks(constraints, value_access) do
    checks = []

    # For integers, parse the string value
    parsed =
      quote do
        String.to_integer(unquote(value_access) || "0")
      end

    # min
    checks =
      case Map.get(constraints, :min) do
        nil ->
          checks

        min ->
          check = quote(do: unquote(parsed) >= unquote(min))
          [check | checks]
      end

    # max
    checks =
      case Map.get(constraints, :max) do
        nil ->
          checks

        max ->
          check = quote(do: unquote(parsed) <= unquote(max))
          [check | checks]
      end

    checks
  end

  @doc """
  Returns the error message for a constraint type.
  """
  def error_message(:required, _), do: "is required"
  def error_message(:min_length, min), do: "must be at least #{min} characters"
  def error_message(:max_length, max), do: "must be at most #{max} characters"
  def error_message(:min, min), do: "must be at least #{min}"
  def error_message(:max, max), do: "must be at most #{max}"
  def error_message(:match, _), do: "is invalid"

  @doc """
  Returns all error checks with their messages for a validation.

  Each check is a tuple of {check_type, constraint_value, error_message}.
  Used to generate error list calculations.
  """
  def error_checks(validation) do
    checks = []

    # Required check
    checks =
      if validation.required do
        [{:required, nil, error_message(:required, nil)} | checks]
      else
        checks
      end

    # Type-specific constraints
    checks = checks ++ constraint_error_checks(validation.type, validation.constraints)

    Enum.reverse(checks)
  end

  defp constraint_error_checks(:string, constraints) do
    checks = []

    checks =
      case Map.get(constraints, :min_length) do
        nil -> checks
        min -> [{:min_length, min, error_message(:min_length, min)} | checks]
      end

    checks =
      case Map.get(constraints, :max_length) do
        nil -> checks
        max -> [{:max_length, max, error_message(:max_length, max)} | checks]
      end

    checks =
      case Map.get(constraints, :match) do
        nil -> checks
        regex -> [{:match, regex, error_message(:match, regex)} | checks]
      end

    checks
  end

  defp constraint_error_checks(:integer, constraints) do
    checks = []

    checks =
      case Map.get(constraints, :min) do
        nil -> checks
        min -> [{:min, min, error_message(:min, min)} | checks]
      end

    checks =
      case Map.get(constraints, :max) do
        nil -> checks
        max -> [{:max, max, error_message(:max, max)} | checks]
      end

    checks
  end

  defp constraint_error_checks(_, _), do: []
end
