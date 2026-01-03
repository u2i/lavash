defmodule Lavash.Form.ValidationTranspiler do
  @moduledoc """
  Transpiles Ash resource validations (from `validations do` block) to client-side validation.

  Unlike ConstraintTranspiler which reads type constraints on attributes,
  this module reads explicit validations which support custom messages.

  ## Example

  In your Ash resource:

      validations do
        validate present(:card_number), message: "Enter a card number"
        validate string_length(:card_number, min: 15, max: 16), message: "Enter a valid card number"
      end

  These messages will be used in client-side validation instead of the generic defaults.
  """

  @doc """
  Extracts validations for a specific action from an Ash resource.

  Returns a map of field_name => list of validation specs.
  Each validation spec contains:
  - :type - the validation type (:present, :string_length, etc.)
  - :opts - validation options (min, max, etc.)
  - :message - custom message (or nil for default)
  """
  def extract_validations_for_action(resource, action_name) do
    action = get_action(resource, action_name)

    if action do
      action_type = action.type
      validations = Ash.Resource.Info.validations(resource, action_type)

      # Group validations by field
      validations
      |> Enum.flat_map(&extract_field_validations/1)
      |> Enum.group_by(fn {field, _spec} -> field end, fn {_field, spec} -> spec end)
    else
      %{}
    end
  end

  @doc """
  Gets the custom message for a validation, or generates a default.

  Supports interpolation of variables like %{min}, %{max}.
  """
  def get_message(validation_spec, value \\ nil) do
    if validation_spec.message do
      interpolate_message(validation_spec.message, validation_spec.opts, value)
    else
      default_message(validation_spec.type, validation_spec.opts)
    end
  end

  @doc """
  Checks if a resource has any custom-message validations we should use.

  Returns true if there are validations with custom messages that would
  override the default constraint transpiler messages.
  """
  def has_custom_validations?(resource, action_name) do
    validations = extract_validations_for_action(resource, action_name)

    validations
    |> Map.values()
    |> List.flatten()
    |> Enum.any?(fn spec -> spec.message != nil end)
  end

  # Private functions

  defp get_action(resource, action_name) do
    Ash.Resource.Info.action(resource, action_name)
  end

  # Extract field-level validations from an Ash.Resource.Validation struct
  defp extract_field_validations(%{module: module, opts: opts, message: custom_message}) do
    case module do
      Ash.Resource.Validation.Present ->
        extract_present_validations(opts, custom_message)

      Ash.Resource.Validation.StringLength ->
        extract_string_length_validations(opts, custom_message)

      Ash.Resource.Validation.Numericality ->
        extract_numericality_validations(opts, custom_message)

      Ash.Resource.Validation.Match ->
        extract_match_validations(opts, custom_message)

      _ ->
        # Unknown validation type - skip for now
        []
    end
  end

  defp extract_present_validations(opts, custom_message) do
    # present/1 stores attributes as :attributes (list)
    attributes = opts[:attributes] || List.wrap(opts[:attribute]) || []

    Enum.map(attributes, fn attr ->
      {attr,
       %{
         type: :required,
         opts: %{},
         message: custom_message
       }}
    end)
  end

  defp extract_string_length_validations(opts, custom_message) do
    attr = opts[:attribute]

    if attr do
      validation_opts =
        opts
        |> Keyword.take([:min, :max, :exact])
        |> Enum.into(%{})

      type =
        cond do
          validation_opts[:exact] -> :exact_length
          validation_opts[:min] && validation_opts[:max] -> :length_between
          validation_opts[:min] -> :min_length
          validation_opts[:max] -> :max_length
          true -> :string_length
        end

      [{attr, %{type: type, opts: validation_opts, message: custom_message}}]
    else
      []
    end
  end

  defp extract_numericality_validations(opts, custom_message) do
    attr = opts[:attribute]

    if attr do
      validation_opts =
        opts
        |> Keyword.take([:greater_than, :greater_than_or_equal_to, :less_than, :less_than_or_equal_to])
        |> Enum.into(%{})

      [{attr, %{type: :numericality, opts: validation_opts, message: custom_message}}]
    else
      []
    end
  end

  defp extract_match_validations(opts, custom_message) do
    attr = opts[:attribute]

    if attr do
      [{attr, %{type: :match, opts: %{match: opts[:match]}, message: custom_message}}]
    else
      []
    end
  end

  # Interpolate %{var} placeholders in messages
  defp interpolate_message(message, opts, _value) do
    Enum.reduce(opts, message, fn {key, val}, msg ->
      String.replace(msg, "%{#{key}}", to_string(val))
    end)
  end

  # Default messages for validation types (fallback when no custom message)
  defp default_message(:required, _opts), do: "is required"
  defp default_message(:min_length, %{min: min}), do: "must be at least #{min} characters"
  defp default_message(:max_length, %{max: max}), do: "must be at most #{max} characters"

  defp default_message(:length_between, %{min: min, max: max}),
    do: "must be between #{min} and #{max} characters"

  defp default_message(:exact_length, %{exact: exact}), do: "must be exactly #{exact} characters"
  defp default_message(:match, _opts), do: "is invalid"

  defp default_message(:numericality, opts) do
    cond do
      opts[:greater_than] -> "must be greater than #{opts[:greater_than]}"
      opts[:greater_than_or_equal_to] -> "must be at least #{opts[:greater_than_or_equal_to]}"
      opts[:less_than] -> "must be less than #{opts[:less_than]}"
      opts[:less_than_or_equal_to] -> "must be at most #{opts[:less_than_or_equal_to]}"
      true -> "is invalid"
    end
  end

  defp default_message(_, _), do: "is invalid"
end
