defmodule Lavash.SyncedVarTest do
  @moduledoc """
  Unit tests for priv/static/synced_var.js, run in Deno via DenoRider.

  Covers pure logic the browser e2e can't pin down deterministically:
  deepEqual value semantics and the mount-time seed() state (issue #30).
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  # Strip ES module syntax so the file evaluates as a plain script.
  @source File.read!("priv/static/synced_var.js")
          |> String.replace("export default", "// export default")
          |> String.replace("export ", "")

  setup_all do
    {:ok, pid} = DenoRider.start()
    %{pid: pid}
  end

  defp run_js(body, %{pid: pid}) do
    js = """
    (function() {
      globalThis.window = globalThis.window || {};
      #{@source}
      #{body}
    })()
    """

    case DenoRider.eval(js, pid: pid) do
      {:ok, result} -> result
      {:error, error} -> raise "JS evaluation failed: #{inspect(error)}"
    end
  end

  defp deep_equal(a, b, ctx) do
    run_js("return deepEqual(#{Jason.encode!(a)}, #{Jason.encode!(b)});", ctx)
  end

  describe "deepEqual" do
    test "primitives and null", ctx do
      assert deep_equal(1, 1, ctx)
      refute deep_equal(1, 2, ctx)
      assert deep_equal("a", "a", ctx)
      assert deep_equal(nil, nil, ctx)
      refute deep_equal(nil, 0, ctx)
    end

    test "arrays compare recursively", ctx do
      assert deep_equal([1, [2, 3]], [1, [2, 3]], ctx)
      refute deep_equal([1, 2], [1, 2, 3], ctx)
    end

    test "plain objects compare by value (issue #30)", ctx do
      assert deep_equal(%{a: 1, b: [1, 2]}, %{a: 1, b: [1, 2]}, ctx)
      refute deep_equal(%{a: 1}, %{a: 2}, ctx)
      refute deep_equal(%{a: 1}, %{a: 1, b: 2}, ctx)
      refute deep_equal(%{a: 1, b: 2}, %{a: 1}, ctx)
    end

    test "objects nested in arrays", ctx do
      assert deep_equal([%{id: 1, tags: ["x"]}], [%{id: 1, tags: ["x"]}], ctx)
      refute deep_equal([%{id: 1}], [%{id: 2}], ctx)
    end

    test "object vs array never equal", ctx do
      refute deep_equal(%{}, [], ctx)
      refute deep_equal([], %{}, ctx)
    end
  end

  describe "serverSet with object values" do
    test "pending object value confirms on matching server patch", ctx do
      result =
        run_js(
          """
          const sv = new SyncedVar(null, {});
          sv.setOptimistic({kind: "edit", id: 7});
          const pendingBefore = sv.isPending;
          sv.serverSet({kind: "edit", id: 7});
          return { pendingBefore, pendingAfter: sv.isPending };
          """,
          ctx
        )

      assert result == %{"pendingBefore" => true, "pendingAfter" => false}
    end
  end

  describe "seed (issue #30)" do
    test "seeds the value as confirmed — no pending window", ctx do
      result =
        run_js(
          """
          const sv = new SyncedVar(null, {});
          sv.seed("42");
          return { pending: sv.isPending, value: sv.value, confirmed: sv.confirmedValue };
          """,
          ctx
        )

      assert result == %{"pending" => false, "value" => "42", "confirmed" => "42"}
    end

    test "animated seed jumps straight to visible; delegate gets onSeedOpen only", ctx do
      result =
        run_js(
          """
          const calls = [];
          const sv = new SyncedVar(null, { animated: { duration: 200 } });
          sv.setDelegate(new Proxy({}, { get: (_t, name) => (..._args) => calls.push(name) }));
          sv.seed("open-id");
          return { phase: sv.getPhase(), pending: sv.isPending, calls };
          """,
          ctx
        )

      assert result == %{"phase" => "visible", "pending" => false, "calls" => ["onSeedOpen"]}
    end

    test "animated seed with unresolved async lands in loading, resolved async in visible", ctx do
      result =
        run_js(
          """
          const loading = new SyncedVar(null, { animated: { duration: 200, async: "form" } });
          loading.seed("x");
          const visible = new SyncedVar(null, { animated: { duration: 200, async: "form" } });
          visible.isAsyncReady = true;
          visible.seed("x");
          return { loading: loading.getPhase(), visible: visible.getPhase() };
          """,
          ctx
        )

      assert result == %{"loading" => "loading", "visible" => "visible"}
    end

    test "seeding null stays idle and not pending", ctx do
      result =
        run_js(
          """
          const sv = new SyncedVar(null, { animated: { duration: 200 } });
          sv.seed(null);
          return { phase: sv.getPhase(), pending: sv.isPending };
          """,
          ctx
        )

      assert result == %{"phase" => "idle", "pending" => false}
    end

    test "server patch echoing the seeded value is a clean no-op", ctx do
      result =
        run_js(
          """
          const sv = new SyncedVar(null, { animated: { duration: 200 } });
          sv.seed("42");
          const changed = sv.serverSet("42");
          return { changed, pending: sv.isPending, phase: sv.getPhase() };
          """,
          ctx
        )

      assert result == %{"changed" => false, "pending" => false, "phase" => "visible"}
    end
  end
end
