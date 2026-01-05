defmodule Lavash.Rx.TranspilerIntegrationTest do
  @moduledoc """
  Integration tests that verify Elixir expressions and their JS transpilations
  produce identical results when evaluated with the same state.

  Uses DenoRider to run the generated JavaScript in Deno runtime.
  """
  use ExUnit.Case, async: false

  alias Lavash.Rx.Transpiler

  @moduletag :integration

  setup_all do
    {:ok, pid} = DenoRider.start()
    %{deno_pid: pid}
  end

  describe "transpiler parity - arithmetic" do
    test "addition produces same result", %{deno_pid: pid} do
      assert_parity("@a + @b", %{a: 5, b: 3}, pid)
    end

    test "subtraction produces same result", %{deno_pid: pid} do
      assert_parity("@a - @b", %{a: 10, b: 4}, pid)
    end

    test "multiplication produces same result", %{deno_pid: pid} do
      assert_parity("@a * @b", %{a: 6, b: 7}, pid)
    end

    test "division produces same result", %{deno_pid: pid} do
      assert_parity("@a / @b", %{a: 20, b: 4}, pid)
    end

    test "complex arithmetic", %{deno_pid: pid} do
      assert_parity("@a + @b * @c", %{a: 1, b: 2, c: 3}, pid)
    end
  end

  describe "transpiler parity - comparisons" do
    test "equality", %{deno_pid: pid} do
      assert_parity("@a == @b", %{a: 5, b: 5}, pid)
      assert_parity("@a == @b", %{a: 5, b: 3}, pid)
    end

    test "inequality", %{deno_pid: pid} do
      assert_parity("@a != @b", %{a: 5, b: 3}, pid)
      assert_parity("@a != @b", %{a: 5, b: 5}, pid)
    end

    test "greater than", %{deno_pid: pid} do
      assert_parity("@a > @b", %{a: 5, b: 3}, pid)
      assert_parity("@a > @b", %{a: 3, b: 5}, pid)
    end

    test "less than", %{deno_pid: pid} do
      assert_parity("@a < @b", %{a: 3, b: 5}, pid)
      assert_parity("@a < @b", %{a: 5, b: 3}, pid)
    end

    test "greater than or equal", %{deno_pid: pid} do
      assert_parity("@a >= @b", %{a: 5, b: 5}, pid)
      assert_parity("@a >= @b", %{a: 5, b: 3}, pid)
    end

    test "less than or equal", %{deno_pid: pid} do
      assert_parity("@a <= @b", %{a: 5, b: 5}, pid)
      assert_parity("@a <= @b", %{a: 3, b: 5}, pid)
    end
  end

  describe "transpiler parity - logical operators" do
    test "and operator", %{deno_pid: pid} do
      assert_parity("@a and @b", %{a: true, b: true}, pid)
      assert_parity("@a and @b", %{a: true, b: false}, pid)
      assert_parity("@a and @b", %{a: false, b: true}, pid)
    end

    test "or operator", %{deno_pid: pid} do
      assert_parity("@a or @b", %{a: true, b: false}, pid)
      assert_parity("@a or @b", %{a: false, b: false}, pid)
    end

    test "not operator", %{deno_pid: pid} do
      assert_parity("not @a", %{a: true}, pid)
      assert_parity("not @a", %{a: false}, pid)
    end

    test "combined logical", %{deno_pid: pid} do
      assert_parity("@a and @b or @c", %{a: true, b: false, c: true}, pid)
    end
  end

  describe "transpiler parity - conditionals" do
    test "if-else with boolean", %{deno_pid: pid} do
      assert_parity(~s|if @active, do: "on", else: "off"|, %{active: true}, pid)
      assert_parity(~s|if @active, do: "on", else: "off"|, %{active: false}, pid)
    end

    test "if-else with numbers", %{deno_pid: pid} do
      assert_parity("if @count > 0, do: @count, else: 0", %{count: 5}, pid)
      assert_parity("if @count > 0, do: @count, else: 0", %{count: -3}, pid)
    end

    test "nested if", %{deno_pid: pid} do
      code = "if @a, do: (if @b, do: 1, else: 2), else: 3"
      assert_parity(code, %{a: true, b: true}, pid)
      assert_parity(code, %{a: true, b: false}, pid)
      assert_parity(code, %{a: false, b: true}, pid)
    end
  end

  describe "transpiler parity - String functions" do
    test "String.length", %{deno_pid: pid} do
      assert_parity("String.length(@text)", %{text: "hello"}, pid)
      assert_parity("String.length(@text)", %{text: ""}, pid)
    end

    test "String.trim", %{deno_pid: pid} do
      assert_parity("String.trim(@text)", %{text: "  hello  "}, pid)
    end

    test "String.starts_with?", %{deno_pid: pid} do
      assert_parity(~s|String.starts_with?(@text, "he")|, %{text: "hello"}, pid)
      assert_parity(~s|String.starts_with?(@text, "xx")|, %{text: "hello"}, pid)
    end

    test "String.ends_with?", %{deno_pid: pid} do
      assert_parity(~s|String.ends_with?(@text, "lo")|, %{text: "hello"}, pid)
      assert_parity(~s|String.ends_with?(@text, "xx")|, %{text: "hello"}, pid)
    end

    test "String.contains?", %{deno_pid: pid} do
      assert_parity(~s|String.contains?(@text, "ell")|, %{text: "hello"}, pid)
      assert_parity(~s|String.contains?(@text, "xxx")|, %{text: "hello"}, pid)
    end

    test "String.slice", %{deno_pid: pid} do
      assert_parity("String.slice(@text, 0, 2)", %{text: "hello"}, pid)
      assert_parity("String.slice(@text, 1, 3)", %{text: "hello"}, pid)
    end

    test "String.replace with regex", %{deno_pid: pid} do
      assert_parity(~s|String.replace(@text, ~r/\\d/, "")|, %{text: "a1b2c3"}, pid)
    end
  end

  describe "transpiler parity - Enum functions" do
    test "Enum.count / length", %{deno_pid: pid} do
      assert_parity("length(@items)", %{items: [1, 2, 3]}, pid)
      assert_parity("length(@items)", %{items: []}, pid)
    end

    test "Enum.member? / in", %{deno_pid: pid} do
      assert_parity(~s|@val in ["a", "b", "c"]|, %{val: "b"}, pid)
      assert_parity(~s|@val in ["a", "b", "c"]|, %{val: "x"}, pid)
    end

    test "Enum.join", %{deno_pid: pid} do
      assert_parity(~s|Enum.join(@items, ", ")|, %{items: ["a", "b", "c"]}, pid)
      assert_parity(~s|Enum.join(@items, "-")|, %{items: [1, 2, 3]}, pid)
    end
  end

  describe "transpiler parity - string concatenation" do
    test "<> operator", %{deno_pid: pid} do
      assert_parity(~s|"$" <> @amount|, %{amount: "100"}, pid)
      assert_parity("@first <> @last", %{first: "hello", last: "world"}, pid)
    end
  end

  describe "transpiler parity - list operations" do
    test "++ operator", %{deno_pid: pid} do
      assert_parity("@a ++ @b", %{a: [1, 2], b: [3, 4]}, pid)
    end
  end

  # Helper to assert that Elixir and JS produce the same result
  defp assert_parity(elixir_code, state, deno_pid) do
    # Evaluate in Elixir
    elixir_result = eval_elixir(elixir_code, state)

    # Transpile and evaluate in JS
    js_code = Transpiler.to_js(elixir_code)
    js_result = eval_js(js_code, state, deno_pid)

    assert elixir_result == js_result,
           """
           Parity mismatch for: #{elixir_code}
           State: #{inspect(state)}
           Elixir result: #{inspect(elixir_result)}
           JS code: #{js_code}
           JS result: #{inspect(js_result)}
           """
  end

  # Evaluate Elixir expression with @var references bound to state
  defp eval_elixir(code, state) do
    # Convert state keys to module attribute-style bindings
    bindings = Enum.map(state, fn {k, v} -> {k, v} end)

    # Parse the code and transform @var to var
    {:ok, ast} = Code.string_to_quoted(code)
    transformed_ast = transform_assigns(ast)

    {result, _} = Code.eval_quoted(transformed_ast, bindings)
    normalize_result(result)
  end

  # Transform @var references to plain var references for eval
  defp transform_assigns({:@, _, [{var, _, _}]}) do
    {var, [], nil}
  end

  defp transform_assigns({form, meta, args}) when is_list(args) do
    {transform_assigns(form), meta, Enum.map(args, &transform_assigns/1)}
  end

  defp transform_assigns({left, right}) do
    {transform_assigns(left), transform_assigns(right)}
  end

  defp transform_assigns(list) when is_list(list) do
    Enum.map(list, &transform_assigns/1)
  end

  defp transform_assigns(other), do: other

  # Evaluate JS expression in Deno
  defp eval_js(js_code, state, deno_pid) do
    # Build state object for JS
    state_json = Jason.encode!(state)

    # Wrap the expression in a function that receives state
    js_wrapper = """
    (function() {
      const state = #{state_json};
      return #{js_code};
    })()
    """

    case DenoRider.eval(js_wrapper, pid: deno_pid) do
      {:ok, result} -> normalize_result(result)
      {:error, error} -> raise "JS evaluation failed: #{inspect(error)}"
    end
  end

  # Normalize results for comparison (handle float/int differences, etc.)
  defp normalize_result(result) when is_float(result) do
    # Round to avoid floating point precision issues
    Float.round(result, 10)
  end

  defp normalize_result(result), do: result
end
