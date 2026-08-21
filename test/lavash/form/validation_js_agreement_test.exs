defmodule Lavash.Form.ValidationJsAgreementTest do
  @moduledoc """
  Three-way agreement tests for form constraint validation (#124/#125):
  the SERVER (fire-ASTs compiled via `Lavash.Rx.Cache`), the CLIENT
  (the same ASTs transpiled to JS, executed in Deno), and the
  expected truth must all agree — and `_valid` must be true exactly
  when `_errors` is empty.

  Before the consolidation these were three hand-written
  implementations that had drifted (inverted regex call in the
  client `_valid`; lenient client integer parsing; untrimmed match in
  server `_errors`). Now one AST feeds both sides, and this suite
  pins the contract.
  """
  use ExUnit.Case, async: false

  alias Lavash.Form.{ConstraintTranspiler, ValidationJs}

  @moduletag :integration

  setup_all do
    {:ok, pid} = DenoRider.start()
    %{deno_pid: pid}
  end

  @string_validation %{
    field: :code,
    required: true,
    type: :string,
    constraints: %{match: ~r/^[A-Z]{3}$/, min_length: 2}
  }

  @integer_validation %{
    field: :age,
    required: true,
    type: :integer,
    constraints: %{min: 18, max: 150}
  }

  test "match: constraint — server, client, and truth agree", %{deno_pid: pid} do
    cases = [
      {"ABC", true},
      {"XYZ", true},
      # unified semantics: match runs on the TRIMMED value (server
      # _errors used to match untrimmed while _valid trimmed)
      {" ABC ", true},
      {"abc", false},
      {"AB", false},
      {"ABCD", false},
      {"", false},
      {nil, false}
    ]

    assert_three_way_agreement(@string_validation, cases, pid)
  end

  test "integer constraints — server, client, and truth agree", %{deno_pid: pid} do
    cases = [
      {"18", true},
      {"150", true},
      # unified semantics: strict full-string parse on BOTH sides
      # (client used to parseInt leniently; "18abc" was 18)
      {" 18 ", true},
      {"18abc", false},
      {"abc", false},
      {"17", false},
      {"151", false},
      {"", false}
    ]

    assert_three_way_agreement(@integer_validation, cases, pid)
  end

  test "required-only empty value shows ONLY the required message", %{deno_pid: pid} do
    # The old client JS showed constraint messages alongside
    # "is required" for empty required fields; the server never did.
    {_valid, errors} = client_eval(@string_validation, "", pid)
    assert errors == ["is required"]
  end

  defp assert_three_way_agreement(validation, cases, pid) do
    checks = ConstraintTranspiler.field_checks(validation, :form_params)
    valid_ast = ConstraintTranspiler.valid_ast(checks)

    for {input, expected_valid} <- cases do
      deps = %{form_params: %{to_string(validation.field) => input}}

      server_valid =
        Lavash.Rx.Cache.compile_rx(__MODULE__, Lavash.Rx.transform_at_refs(valid_ast)).(deps)

      server_errors =
        Enum.flat_map(checks, fn %{fire_ast: ast, message: msg} ->
          if Lavash.Rx.Cache.compile_rx(__MODULE__, Lavash.Rx.transform_at_refs(ast)).(deps),
            do: [msg],
            else: []
        end)

      {client_valid, client_errors} = client_eval(validation, input, pid)

      assert server_valid == expected_valid,
             "server _valid for #{inspect(input)}: got #{server_valid}"

      assert client_valid == expected_valid,
             "client _valid for #{inspect(input)}: got #{client_valid}"

      assert client_errors == server_errors,
             "errors diverge for #{inspect(input)}: server #{inspect(server_errors)} " <>
               "vs client #{inspect(client_errors)}"

      assert server_errors == [] == expected_valid,
             "_errors disagrees with _valid for #{inspect(input)}: #{inspect(server_errors)}"
    end
  end

  defp client_eval(validation, input, pid) do
    checks = ConstraintTranspiler.field_checks(validation, :form_params)
    valid_ast = ConstraintTranspiler.valid_ast(checks)

    valid_js = ValidationJs.generate_field_validation_js(:f_valid, valid_ast)

    errors_js =
      ValidationJs.generate_field_errors_js(:f_errors, to_string(validation.field), checks, [])

    state = %{form_params: %{to_string(validation.field) => input}}

    wrapper = """
    (() => {
      const fns = {
    #{valid_js},
    #{errors_js}
      };
      const state = #{Jason.encode!(state)};
      return JSON.stringify({valid: fns.f_valid(state), errors: fns.f_errors(state)});
    })()
    """

    {:ok, json} = DenoRider.eval(wrapper, pid: pid)
    %{"valid" => valid, "errors" => errors} = Jason.decode!(json)
    {valid, errors}
  end
end
