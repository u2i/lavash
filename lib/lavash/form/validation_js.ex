defmodule Lavash.Form.ValidationJs do
  @moduledoc """
  Generates JavaScript for form field validation and error checking.

  Shared by both `ColocatedTransformer` (compile-time) and `JsGenerator` (runtime).
  Handles constraint-based validation (required, min_length, max, match, etc.)
  and custom error checks from `extend_errors`.
  """

  @doc """
  Generate JS for a field validation derive (returns boolean).

  Transpiles the SAME `valid_ast` the server compiles
  (`Lavash.Form.ConstraintTranspiler.valid_ast/1`) — one source of
  truth for constraint semantics (#125).
  """
  def generate_field_validation_js(name, valid_ast) do
    """
      #{name}(state) {
        return #{Lavash.Optimistic.Transpiler.ast_to_js(valid_ast)};
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
  Generate JS for a field errors derive (returns a list of messages).

  Constraint messages come from the SAME fire-ASTs the server
  compiles (`Lavash.Form.ConstraintTranspiler.field_checks/3`) —
  empty-value gating is encoded in the ASTs, so client and server
  cannot disagree about when a message shows (#125). Custom
  `extend_errors` conditions are transpiled unconditionally (server
  parity — visibility is the touched/submitted tracker's job), and
  pushed server errors merge in deduplicated.

  Options:
  - `:expand_defrx` — source expander for custom error conditions
  - `:server_errors_field` — state field holding pushed server errors
  """
  def generate_field_errors_js(name, field_str, checks, custom_errors, opts \\ []) do
    expand_defrx = Keyword.get(opts, :expand_defrx, &Function.identity/1)

    constraint_pushes =
      Enum.map(checks, fn %{fire_ast: fire_ast, message: message} ->
        "if (#{Lavash.Optimistic.Transpiler.ast_to_js(fire_ast)}) push(#{Jason.encode!(message)});"
      end)

    custom_pushes =
      Enum.map(custom_errors, fn error ->
        expanded_condition = expand_defrx.(error.condition.source)
        js_condition = Lavash.Optimistic.Transpiler.to_js(expanded_condition)

        msg_js =
          case error.message do
            %Lavash.Rx{source: source} ->
              "(#{Lavash.Optimistic.Transpiler.to_js(expand_defrx.(source))})"

            static_string when is_binary(static_string) ->
              Jason.encode!(static_string)
          end

        "if (#{js_condition}) push(#{msg_js});"
      end)

    server_merge =
      case Keyword.get(opts, :server_errors_field) do
        nil ->
          ""

        server_errors_field ->
          "const serverErrors = state.#{server_errors_field}?.[#{Jason.encode!(field_str)}] || [];\n" <>
            "    for (const e of serverErrors) push(e);"
      end

    pushes = Enum.map_join(constraint_pushes ++ custom_pushes, "\n    ", & &1)

    """
      #{name}(state) {
        const errors = [];
        const push = (m) => { if (!errors.includes(m)) errors.push(m); };
        #{pushes}
        #{server_merge}
        return errors;
      }
    """
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
end
