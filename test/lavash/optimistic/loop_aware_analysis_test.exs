defmodule Lavash.Optimistic.LoopAwareAnalysisTest do
  @moduledoc """
  Tests that optimistic-template analysis is loop-aware: a `:for` loop
  variable counts as optimistic-derived only when its SOURCE list is
  optimistic. Expressions over a static loop (non-optimistic source) are
  server-rendered and must not produce client-side subtree derives.
  """
  use ExUnit.Case, async: true

  defp subtree_derives(mod),
    do: Spark.Dsl.Extension.get_persisted(mod, :lavash_subtree_derives) || []

  defmodule OptimisticLoop do
    @moduledoc false
    use Lavash.LiveView

    # `rows` is an optimistic STATE field — a :for over it re-renders on the
    # client, so the row body needs client transpilation.
    state :rows, :map, default: %{}, optimistic: true

    template do
      ~H"""
      <ul>
        <li :for={r <- @rows}>{r}</li>
      </ul>
      """
    end
  end

  defmodule StaticLoop do
    @moduledoc false
    use Lavash.LiveView

    state :n, :integer, default: 0, optimistic: true
    # `static_rows` is a NON-optimistic calculation. The :for over it never
    # re-renders on the client, so its body is server-rendered and must NOT
    # become a subtree derive — even though the module has optimistic state.
    calculate :static_rows, rx(Enum.to_list(1..3)), optimistic: false

    template do
      ~H"""
      <ul>
        <li :for={r <- @static_rows}>{r}</li>
      </ul>
      """
    end
  end

  describe "loop-aware subtree derive extraction" do
    test ":for over an optimistic list produces a subtree derive" do
      derives = subtree_derives(OptimisticLoop)
      assert derives != [], "expected a subtree derive for a :for over optimistic @rows"
      assert Enum.any?(derives, &("rows" in &1.deps))
    end

    test ":for over a non-optimistic calculation produces no subtree derive" do
      # The loop body references only the loop var `r` (bound to a
      # non-optimistic source), so nothing in the subtree is optimistic —
      # server-rendered only.
      assert subtree_derives(StaticLoop) == []
    end
  end

  describe "compile-time error for untranspilable optimistic expressions" do
    test "an untranspilable helper call over optimistic state raises at compile time" do
      src = """
      defmodule Lavash.Optimistic.LoopAwareAnalysisTest.BadHelper do
        use Lavash.LiveView

        state :rows, :map, default: %{}, optimistic: true

        def badge_class(_x), do: "badge"

        template do
          ~H\"\"\"
          <ul>
            <li :for={r <- @rows}>{badge_class(r)}</li>
          </ul>
          \"\"\"
        end
      end
      """

      err = assert_raise Spark.Error.DslError, fn -> Code.compile_string(src, "nofile") end
      msg = Exception.message(err)
      assert msg =~ "Cannot transpile"
      assert msg =~ "badge_class"
      assert msg =~ "defrx"
    end

    test "the SAME helper in a STATIC loop does NOT raise (server-rendered)" do
      # Identical body, but the loop source is non-optimistic — the row is
      # server-rendered, so the helper is fine and must not error.
      src = """
      defmodule Lavash.Optimistic.LoopAwareAnalysisTest.StaticHelper do
        use Lavash.LiveView

        state :toggle, :boolean, default: false, optimistic: true
        calculate :static_rows, rx([1, 2, 3]), optimistic: false

        def badge_class(_x), do: "badge"

        template do
          ~H\"\"\"
          <ul>
            <li :for={r <- @static_rows}>{badge_class(r)}</li>
          </ul>
          \"\"\"
        end
      end
      """

      assert [{mod, _} | _] = Code.compile_string(src, "nofile")
      assert function_exported?(mod, :render, 1)
    end

    test "transpilable expressions over optimistic state do NOT raise" do
      # An optimistic :for whose body uses only transpilable operations
      # (field access, string concat) compiles cleanly and IS a derive.
      src = """
      defmodule Lavash.Optimistic.LoopAwareAnalysisTest.TranspilableOk do
        use Lavash.LiveView

        state :rows, :map, default: %{}, optimistic: true

        template do
          ~H\"\"\"
          <ul>
            <li :for={r <- @rows}>{r.label <> "!"}</li>
          </ul>
          \"\"\"
        end
      end
      """

      assert [{mod, _} | _] = Code.compile_string(src, "nofile")
      assert function_exported?(mod, :render, 1)
      assert Spark.Dsl.Extension.get_persisted(mod, :lavash_subtree_derives) != []
    end
  end
end
