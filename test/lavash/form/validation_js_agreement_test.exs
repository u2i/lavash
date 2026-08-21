defmodule Lavash.Form.ValidationJsAgreementTest do
  @moduledoc """
  Agreement tests between the generated `_valid` JS and `_errors` JS
  for the same constraints — the standing guard from the #124 audit.

  The two generators are separate hand-written implementations of the
  same semantics; when they disagree, the failure mode is invisible
  (a stuck-false `_valid` renders as "button greyed until the
  round-trip", indistinguishable from latency, while `_errors` shows
  nothing wrong). #124 was exactly this: the `match:` constraint's
  `_valid` check had its regex call inverted and was permanently
  false, masked for months.

  Executes the generated JS in Deno and asserts, for valid AND
  invalid input: `_valid` is true exactly when `_errors` is empty.
  """
  use ExUnit.Case, async: false

  alias Lavash.Form.ValidationJs

  @moduletag :integration

  setup_all do
    {:ok, pid} = DenoRider.start()
    %{deno_pid: pid}
  end

  @validation %{
    field: :code,
    required: true,
    type: :string,
    constraints: %{match: ~r/^[A-Z]{3}$/, min_length: 2}
  }

  test "match: constraint — _valid and _errors agree for valid and invalid input",
       %{deno_pid: pid} do
    cases = [
      # {input, expected_valid}
      {"ABC", true},
      {"XYZ", true},
      {"abc", false},
      {"AB", false},
      {"ABCD", false},
      {"", false},
      {nil, false}
    ]

    for {input, expected_valid} <- cases do
      {valid, errors} = eval_field_js(@validation, input, pid)

      assert valid == expected_valid,
             "_valid for #{inspect(input)}: expected #{expected_valid}, got #{valid}"

      assert errors == [] == expected_valid,
             "_errors for #{inspect(input)} disagrees with _valid: #{inspect(errors)}"
    end
  end

  test "min/max integer constraints — _valid and _errors agree", %{deno_pid: pid} do
    validation = %{field: :age, required: true, type: :integer, constraints: %{min: 18, max: 150}}

    for {input, expected_valid} <- [{"18", true}, {"150", true}, {"17", false}, {"151", false}] do
      {valid, errors} = eval_field_js(validation, input, pid)

      assert valid == expected_valid, "_valid for #{inspect(input)}"
      assert errors == [] == expected_valid, "_errors for #{inspect(input)}"
    end
  end

  # Generate both derives for the field, run them in Deno against the
  # same state, return {valid :: boolean, errors :: list}.
  defp eval_field_js(validation, input, pid) do
    valid_js =
      ValidationJs.generate_field_validation_js(:f_valid, :form_params, validation, false)

    errors_js =
      ValidationJs.generate_field_errors_js(:f_errors, :form_params, validation, [], [], false)

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
