defmodule Lavash.Optimistic.JsValidatorTest do
  use ExUnit.Case, async: true

  alias Lavash.Optimistic.JsValidator

  # These tests exercise the node-backed path; when node isn't on PATH
  # the validator returns :skip and the error assertions below would be
  # meaningless, so skip the module.
  @moduletag skip: is_nil(System.find_executable("node"))

  describe "validate/1" do
    test "accepts a valid generated module" do
      js = """
      export default {
        submit(state) {
          return { messages: [...state.messages, {"role": "user"}], input: "" };
        }
      };
      """

      assert JsValidator.validate(js) == :ok
    end

    test "rejects the historical atom-key transpiler output" do
      # Regression sample: before the map-literal key fix, the transpiler
      # emitted Elixir atom syntax as JS object keys. This exact shape
      # broke consuming bundlers silently.
      js = """
      export default {
        submit(state) {
          return { messages: [...state.messages, {:role: "user"}] };
        }
      };
      """

      assert {:error, message} = JsValidator.validate(js)
      assert message =~ "node --check"
      assert message =~ "generated.mjs"
      refute message =~ "lavash_jscheck_"
    end

    test "rejects generally malformed JS" do
      assert {:error, _} = JsValidator.validate("export default {{{")
    end

    test "returns :skip when disabled via config" do
      Application.put_env(:lavash, :validate_generated_js, false)

      try do
        assert JsValidator.validate("export default {{{") == :skip
      after
        Application.delete_env(:lavash, :validate_generated_js)
      end
    end
  end

  describe "validate!/3" do
    test "raises CompileError attributed to the module's file" do
      env = %{__ENV__ | file: "lib/my_app/some_modal.ex", line: 7}

      error =
        assert_raise CompileError, fn ->
          JsValidator.validate!("export default {{{", MyApp.SomeModal, env)
        end

      assert error.file == "lib/my_app/some_modal.ex"
      assert error.description =~ "MyApp.SomeModal"
      assert error.description =~ "validate_generated_js"
    end

    test "passes through valid JS" do
      assert JsValidator.validate!("export default {};", MyApp.SomeModal, __ENV__) == :ok
    end
  end
end
