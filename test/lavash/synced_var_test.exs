defmodule Lavash.SyncedVarTest do
  @moduledoc """
  Unit tests for priv/static/synced_var.js, run in Deno via DenoRider.

  Covers pure logic the browser e2e can't pin down deterministically:
  deepEqual value semantics, the mount-time seed() state (issue #30),
  and the shared animation-speed multiplier (issue #28).
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  # Strip ES module syntax so the files evaluate as plain scripts.
  @source File.read!("priv/static/synced_var.js")
          |> String.replace("export default", "// export default")
          |> String.replace("export ", "")

  @animator_source File.read!("priv/static/overlay_animator.js")
                   |> String.replace(~r/^import .*$/m, "")
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

  describe "animationSpeed (issue #28)" do
    test "defaults to 1; reads window.Lavash.ANIMATION_SPEED; rejects invalid values", ctx do
      result =
        run_js(
          """
          const before = animationSpeed();
          window.Lavash = window.Lavash || {};
          window.Lavash.ANIMATION_SPEED = 0.1;
          const slowed = animationSpeed();
          window.Lavash.ANIMATION_SPEED = 0;
          const zero = animationSpeed();
          window.Lavash.ANIMATION_SPEED = "fast";
          const nonNumber = animationSpeed();
          delete window.Lavash.ANIMATION_SPEED;
          return { before, slowed, zero, nonNumber };
          """,
          ctx
        )

      assert result == %{"before" => 1, "slowed" => 0.1, "zero" => 1, "nonNumber" => 1}
    end

    test "OverlayAnimator duration scales live with the multiplier", %{pid: pid} do
      js = """
      (function() {
        globalThis.window = globalThis.window || {};
        #{@source}
        #{@animator_source}
        const el = { id: "m", querySelector: () => null };
        const anim = new OverlayAnimator(el, { type: "modal", duration: 200 });
        const normal = anim.duration;
        window.Lavash.ANIMATION_SPEED = 0.5;
        const slowed = anim.duration;
        delete window.Lavash.ANIMATION_SPEED;
        return { normal, slowed };
      })()
      """

      assert {:ok, result} = DenoRider.eval(js, pid: pid)
      assert result == %{"normal" => 200, "slowed" => 400}
    end

    test "phase-machine fallback timeout scales with the multiplier", ctx do
      # 2x speed → the entering fallback (duration/speed + 50) fires at
      # ~150ms instead of ~250ms. Sample the phase at ~200ms: only the
      # scaled timeout has already advanced entering → visible.
      result =
        run_js(
          """
          window.Lavash = window.Lavash || {};
          window.Lavash.ANIMATION_SPEED = 2;
          const sv = new SyncedVar(null, { animated: { duration: 200 } });
          sv.setOptimistic("open");
          return new Promise((resolve) => {
            setTimeout(() => {
              delete window.Lavash.ANIMATION_SPEED;
              resolve(sv.getPhase());
            }, 200);
          });
          """,
          ctx
        )

      assert result == "visible"
    end
  end

  describe "provisional seeds (issue #72)" do
    test "provisional seed is unresolved but NOT pending, and records row ids", ctx do
      result =
        run_js(
          """
          const sv = new SyncedVar([]);
          sv.seed([{id: "u1", name: "Widget"}], { provisional: true, changedIds: ["u1"] });
          return {
            pending: sv.isPending,
            unresolved: sv.isUnresolved,
            ids: Array.from(sv.provisionalIds)
          };
          """,
          ctx
        )

      assert result == %{"pending" => false, "unresolved" => true, "ids" => ["u1"]}
    end

    test "any server arrival resolves a provisional seed", ctx do
      result =
        run_js(
          """
          const sv = new SyncedVar([]);
          sv.seed([{id: "u1"}], { provisional: true, changedIds: ["u1"] });
          sv.serverSet([{id: "real-1"}]);
          return { unresolved: sv.isUnresolved, ids: sv.provisionalIds };
          """,
          ctx
        )

      assert result == %{"unresolved" => false, "ids" => nil}
    end

    test "plain seed (SSR mount seeding, issue #30) stays resolved", ctx do
      result =
        run_js(
          """
          const sv = new SyncedVar(null);
          sv.seed("open");
          return sv.isUnresolved;
          """,
          ctx
        )

      refute result
    end

    test "consecutive provisional seeds merge their row ids", ctx do
      result =
        run_js(
          """
          const sv = new SyncedVar([]);
          sv.seed([{id: "a"}], { provisional: true, changedIds: ["a"] });
          sv.seed([{id: "a"}, {id: "b"}], { provisional: true, changedIds: ["b"] });
          return Array.from(sv.provisionalIds).sort();
          """,
          ctx
        )

      assert result == ["a", "b"]
    end

    test "store hasUnresolved counts pending AND provisional; hasPending only pending", ctx do
      result =
        run_js(
          """
          const store = new SyncedVarStore();
          store.get("rows", []).seed([{id: "u1"}], { provisional: true, changedIds: ["u1"] });
          const before = { pending: store.hasPending, unresolved: store.hasUnresolved,
                           paths: store.getUnresolvedPaths() };
          store.get("count", 0).setOptimistic(5);
          const during = { pending: store.hasPending, unresolved: store.hasUnresolved };
          store.serverUpdate({ rows: [{id: "real"}], count: 5 });
          const after = { pending: store.hasPending, unresolved: store.hasUnresolved };
          return { before, during, after };
          """,
          ctx
        )

      assert result["before"] == %{
               "pending" => false,
               "unresolved" => true,
               "paths" => ["rows"]
             }

      assert result["during"] == %{"pending" => true, "unresolved" => true}
      assert result["after"] == %{"pending" => false, "unresolved" => false}
    end
  end
end
