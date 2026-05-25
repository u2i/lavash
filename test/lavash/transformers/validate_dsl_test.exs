defmodule Lavash.Transformers.ValidateDslTest do
  @moduledoc """
  Cross-entity DSL validations. Each test compiles a tiny `use Lavash.LiveView`
  module via `Code.compile_string` and asserts the validator raises a
  `Spark.Error.DslError` with a useful message — or doesn't, for the happy
  path.

  Compiling in a fresh string keeps each module isolated and avoids
  `Code.purge` dances between tests.
  """
  use ExUnit.Case, async: false

  defp compile!(name, body) do
    source = """
    defmodule #{name} do
      use Lavash.LiveView
      #{body}
      def render(assigns), do: ~H"<div>ok</div>"
    end
    """

    Code.compile_string(source, "nofile")
  rescue
    e -> e
  end

  defp assert_raises_dsl_error(name, body, message_match) do
    err = compile!(name, body)
    assert %Spark.Error.DslError{} = err, "expected DslError, got: #{inspect(err)}"
    assert err.message =~ message_match, "got: #{err.message}"
  end

  describe "duplicate state names" do
    test "raises with the offending name" do
      assert_raises_dsl_error(
        Lavash.Validate.DupState,
        """
        state :count, :integer, default: 0
        state :count, :string, default: ""
        """,
        "state :count is declared more than once"
      )
    end
  end

  describe "duplicate calculation names" do
    test "raises with the offending name" do
      assert_raises_dsl_error(
        Lavash.Validate.DupCalc,
        """
        state :a, :integer, default: 0
        calculate :doubled, rx(@a * 2)
        calculate :doubled, rx(@a * 3)
        """,
        "calculation :doubled is declared more than once"
      )
    end
  end

  describe "duplicate action names" do
    test "raises with the offending name" do
      assert_raises_dsl_error(
        Lavash.Validate.DupAction,
        """
        state :n, :integer, default: 0
        actions do
          action :bump do
            set :n, rx(@n + 1)
          end
          action :bump do
            set :n, rx(@n + 2)
          end
        end
        """,
        "action :bump is declared more than once"
      )
    end
  end

  describe "state/calc name collision" do
    test "raises when a calc shares a name with a state" do
      assert_raises_dsl_error(
        Lavash.Validate.NameCollision,
        """
        state :result, :integer, default: 0
        calculate :result, rx(@result + 1)
        """,
        "shares its name with a `state`"
      )
    end
  end

  describe "reads referencing unknown fields" do
    test "raises when a reads atom matches no field" do
      assert_raises_dsl_error(
        Lavash.Validate.UnknownRead,
        """
        state :n, :integer, default: 0
        actions do
          action :submit, [:value] do
            reads [:n, :nopey]
            run fn assigns -> assigns end
          end
        end
        """,
        "reads :nopey, but no state"
      )
    end

    test "happy path: reads referring to a state + a calculation" do
      result =
        compile!(
          Lavash.Validate.GoodReads,
          """
          state :n, :integer, default: 0
          calculate :doubled, rx(@n * 2)
          actions do
            action :submit, [:value] do
              reads [:n, :doubled]
              run fn assigns -> assigns end
            end
          end
          """
        )

      refute match?(%Spark.Error.DslError{}, result), "unexpected: #{inspect(result)}"
    end
  end

  describe "action sets targeting non-state" do
    test "raises when set target is undeclared" do
      assert_raises_dsl_error(
        Lavash.Validate.BadSet,
        """
        state :a, :integer, default: 0
        actions do
          action :do_it do
            set :nope, rx(@a + 1)
          end
        end
        """,
        "sets :nope, but :nope is not a declared `state`"
      )
    end
  end

  describe "set rx() with unknown @field dep" do
    test "raises when the rx body references an undeclared field" do
      assert_raises_dsl_error(
        Lavash.Validate.BadSetDep,
        """
        state :a, :integer, default: 0
        actions do
          action :do_it do
            set :a, rx(@a + @typo)
          end
        end
        """,
        "references @typo"
      )
    end

    test "happy path: action params are allowed in set rx() deps" do
      result =
        compile!(
          Lavash.Validate.GoodSetDep,
          """
          state :a, :integer, default: 0
          actions do
            action :do_it, [:delta] do
              set :a, rx(@a + @delta)
            end
          end
          """
        )

      refute match?(%Spark.Error.DslError{}, result), "unexpected: #{inspect(result)}"
    end
  end

  describe "calculate rx() with unknown @field dep" do
    test "raises when calc references undeclared field" do
      assert_raises_dsl_error(
        Lavash.Validate.BadCalcDep,
        """
        state :a, :integer, default: 0
        calculate :result, rx(@a + @b)
        """,
        "references @b"
      )
    end
  end

  describe "action guards referencing unknown fields" do
    test "raises when guard isn't a state or calc" do
      assert_raises_dsl_error(
        Lavash.Validate.BadGuard,
        """
        state :n, :integer, default: 0
        actions do
          action :submit, [], [:bogus_guard] do
            set :n, rx(@n + 1)
          end
        end
        """,
        "guard :bogus_guard"
      )
    end

    test "happy path: guard is a declared calc" do
      result =
        compile!(
          Lavash.Validate.GoodGuard,
          """
          state :n, :integer, default: 0
          calculate :ready, rx(@n > 0)
          actions do
            action :submit, [], [:ready] do
              set :n, rx(@n + 1)
            end
          end
          """
        )

      refute match?(%Spark.Error.DslError{}, result), "unexpected: #{inspect(result)}"
    end
  end
end
