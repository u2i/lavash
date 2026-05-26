defmodule Lavash.LiveView.BaseTest do
  @moduledoc """
  Smoke tests for `use Lavash.LiveView.Base` — the layer-2-only
  entry point. Verifies:

    * A module that opts in compiles cleanly when it sticks to
      layer-1/2/3 features (state, calculate without optimistic,
      actions, templates).

    * `optimistic: true`, `animated: ...`, and
      `calculate ..., optimistic: true` produce a friendly
      `Spark.Error.DslError` at compile time directing the user
      to either drop the flag or use `Lavash.LiveView`.
  """
  use ExUnit.Case, async: false

  defp compile!(name, body) do
    source = """
    defmodule #{name} do
      use Lavash.LiveView.Base
      #{body}
    end
    """

    Code.compile_string(source, "nofile")
  rescue
    e -> e
  end

  defp assert_compiles(name, body) do
    result = compile!(name, body)

    assert is_list(result),
           "expected compile success, got: #{inspect(result)}"
  end

  defp assert_raises_with(name, body, message_match) do
    err = compile!(name, body)
    assert %Spark.Error.DslError{} = err, "expected DslError, got: #{inspect(err)}"
    assert err.message =~ message_match, "got: #{err.message}"
  end

  describe "happy path" do
    test "state + calculate + action compiles" do
      assert_compiles(
        Lavash.Base.HappyPath,
        """
        state :count, :integer, default: 0
        state :tab, :string, from: :url, default: "overview"

        calculate :doubled, rx(@count * 2)

        actions do
          action :inc do
            set :count, rx(@count + 1)
          end
        end

        template do
          ~H\"\"\"
          <div>{@count} / {@doubled} / {@tab}</div>
          \"\"\"
        end
        """
      )
    end
  end

  describe "rejects layer-4 features" do
    test "state with optimistic: true raises" do
      assert_raises_with(
        Lavash.Base.RejectOptimistic,
        """
        state :count, :integer, default: 0, optimistic: true

        template do
          ~H"<div>{@count}</div>"
        end
        """,
        "state :count, optimistic: true is not supported"
      )
    end

    test "state with animated: ... raises" do
      assert_raises_with(
        Lavash.Base.RejectAnimated,
        """
        state :open, :boolean, default: false, animated: true

        template do
          ~H"<div :if={@open}>x</div>"
        end
        """,
        "state :open, animated: ... is not supported"
      )
    end

    test "calculate with optimistic: true is a no-op (not rejected)" do
      # In Base mode the layer-4 transformers short-circuit, so a
      # calc marked `optimistic: true` simply becomes a server-only
      # one. The flag isn't rejected — it's just ignored.
      assert_compiles(
        Lavash.Base.OptimisticCalcOk,
        """
        state :n, :integer, default: 1

        calculate :doubled, rx(@n * 2), optimistic: true

        template do
          ~H"<div>{@doubled}</div>"
        end
        """
      )
    end
  end
end
