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
  Per-field checks for a whole form — the shared entry point both the
  server derive builder (`ExpandFields`) and the client JS generator
  (`ExtractColocatedJs`) consume, so field selection is also unified:
  only fields ACCEPTED by the create action get derives (the client
  always filtered this way; the server used to generate junk
  `_valid`/`_errors` derives for non-accepted fields like timestamps
  and foreign keys), and `skip_constraints` empties a field's checks
  on BOTH sides (it used to be client-only).

  Returns `[%{field, checks, valid_ast}]`.
  """
  def form_checks(resource, create_action, params_field, skip_constraints) do
    action = Ash.Resource.Info.action(resource, create_action)
    accepted = if action, do: action.accept || [], else: []

    ash_validations =
      Lavash.Form.ValidationTranspiler.extract_validations_for_action(resource, create_action)

    resource
    |> extract_validations()
    |> Enum.filter(fn v -> accepted == [] or v.field in accepted end)
    |> Enum.map(fn validation ->
      checks =
        if validation.field in skip_constraints do
          []
        else
          ash_messages =
            ash_validations
            |> Map.get(validation.field, [])
            |> build_ash_message_lookup()

          field_checks(validation, params_field, ash_messages)
        end

      %{field: validation.field, checks: checks, valid_ast: valid_ast(checks)}
    end)
  end

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

  @doc """
  THE single source of truth for a field's constraint checks (#125).

  Returns a list of `%{kind, fire_ast, message}` where `fire_ast` is
  a quoted expression that is TRUE when the error fires. The same AST
  is compiled for the server derive (via `Lavash.Rx.Cache`) and
  transpiled to JS for the client (via `Lavash.Optimistic.Transpiler`),
  so client/server drift in constraint semantics is structurally
  impossible. `valid_ast/1` derives the field's `_valid` expression
  from the same checks, so `_valid == (errors == [])` by construction.

  Encoded semantics (matching the pre-consolidation server, with the
  drift points unified):

  - `required` fires when the trimmed value is empty
  - constraint checks fire only when the value is NON-empty (empty is
    the required check's business)
  - string checks operate on the TRIMMED value (`_errors` used to
    match untrimmed while `_valid` matched trimmed)
  - integer parsing is strict full-string via
    `Lavash.Form.Validation.parse_int/1` on both sides (the client
    used to `parseInt` leniently to `NaN`); an unparseable non-empty
    value fires the `:not_number` check with the `:match` message,
    and min/max only fire once parsed

  Messages resolve `ash_messages` overrides at build time.
  """
  def field_checks(validation, params_field, ash_messages \\ %{}) do
    value = value_access_ast(validation.field, params_field)

    required_checks =
      if validation.required do
        [
          %{
            kind: :required,
            fire_ast: empty_ast(value),
            message: message(ash_messages, :required, nil)
          }
        ]
      else
        []
      end

    required_checks ++ constraint_fire_checks(validation, value, ash_messages)
  end

  @doc """
  Derives the `_valid` expression from `field_checks/3` output:
  no check fires. Returns `true` when there are no checks.
  """
  def valid_ast([]), do: quote(do: true)

  def valid_ast(checks) do
    fired =
      checks
      |> Enum.map(& &1.fire_ast)
      |> Enum.reduce(fn ast, acc -> quote(do: unquote(acc) or unquote(ast)) end)

    quote(do: not unquote(fired))
  end

  defp value_access_ast(field, params_field) do
    field_str = to_string(field)

    quote do
      (@unquote(Macro.var(params_field, nil)))[unquote(field_str)]
    end
  end

  defp trimmed_ast(value), do: quote(do: String.trim(unquote(value) || ""))

  defp empty_ast(value),
    do: quote(do: String.length(unquote(trimmed_ast(value))) == 0)

  defp non_empty_ast(value),
    do: quote(do: String.length(unquote(trimmed_ast(value))) > 0)

  defp gated(value, fire), do: quote(do: unquote(non_empty_ast(value)) and unquote(fire))

  defp message(ash_messages, kind, constraint) do
    Map.get(ash_messages, kind) || error_message(kind, constraint)
  end

  defp constraint_fire_checks(%{type: :string, constraints: constraints}, value, ash_messages) do
    trimmed = trimmed_ast(value)

    [
      case Map.get(constraints, :min_length) do
        nil ->
          []

        min ->
          [
            %{
              kind: :min_length,
              fire_ast: gated(value, quote(do: String.length(unquote(trimmed)) < unquote(min))),
              message: message(ash_messages, :min_length, min)
            }
          ]
      end,
      case Map.get(constraints, :max_length) do
        nil ->
          []

        max ->
          [
            %{
              kind: :max_length,
              fire_ast: gated(value, quote(do: String.length(unquote(trimmed)) > unquote(max))),
              message: message(ash_messages, :max_length, max)
            }
          ]
      end,
      case Map.get(constraints, :match) do
        nil ->
          []

        regex ->
          sigil = regex_sigil_ast(regex)

          [
            %{
              kind: :match,
              fire_ast:
                gated(value, quote(do: not String.match?(unquote(trimmed), unquote(sigil)))),
              message: message(ash_messages, :match, regex)
            }
          ]
      end
    ]
    |> List.flatten()
  end

  defp constraint_fire_checks(%{type: :integer, constraints: constraints}, value, ash_messages) do
    parsed = quote(do: Lavash.Form.Validation.parse_int(unquote(value)))

    not_number = [
      %{
        kind: :not_number,
        fire_ast: gated(value, quote(do: is_nil(unquote(parsed)))),
        message: message(ash_messages, :match, nil)
      }
    ]

    bounds =
      [
        case Map.get(constraints, :min) do
          nil ->
            []

          min ->
            [
              %{
                kind: :min,
                fire_ast:
                  gated(
                    value,
                    quote(
                      do:
                        not is_nil(unquote(parsed)) and
                          unquote(parsed) < unquote(min)
                    )
                  ),
                message: message(ash_messages, :min, min)
              }
            ]
        end,
        case Map.get(constraints, :max) do
          nil ->
            []

          max ->
            [
              %{
                kind: :max,
                fire_ast:
                  gated(
                    value,
                    quote(
                      do:
                        not is_nil(unquote(parsed)) and
                          unquote(parsed) > unquote(max)
                    )
                  ),
                message: message(ash_messages, :max, max)
              }
            ]
        end
      ]
      |> List.flatten()

    # The parse gate only matters when a bound exists — a bare
    # :integer field without min/max accepted anything before.
    if bounds == [], do: [], else: not_number ++ bounds
  end

  defp constraint_fire_checks(_validation, _value, _ash_messages), do: []

  # String.match? transpilation requires a literal ~r sigil in the
  # AST (the JS mapping reads the pattern out of the sigil node), and
  # the server compiles the sigil back into the same regex. inspect/1
  # of a regex is its sigil literal — round-trip through the parser.
  defp regex_sigil_ast(regex) do
    {:ok, ast} = Code.string_to_quoted(inspect(regex))
    ast
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
end
