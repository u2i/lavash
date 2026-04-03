defmodule Lavash.Optimistic.ActionJsTest do
  use ExUnit.Case, async: true

  alias Lavash.Optimistic.ActionJs

  defp action(opts \\ []) do
    %Lavash.Actions.Action{
      name: Keyword.get(opts, :name, :test),
      params: Keyword.get(opts, :params),
      when: Keyword.get(opts, :when),
      sets: Keyword.get(opts, :sets, []),
      runs: Keyword.get(opts, :runs, []),
      reads: Keyword.get(opts, :reads, []),
      updates: Keyword.get(opts, :updates, []),
      effects: Keyword.get(opts, :effects, []),
      submits: Keyword.get(opts, :submits, []),
      navigates: Keyword.get(opts, :navigates, []),
      flashes: Keyword.get(opts, :flashes, []),
      invokes: Keyword.get(opts, :invokes, []),
      notify_parents: Keyword.get(opts, :notify_parents, []),
      map_bys: Keyword.get(opts, :map_bys, [])
    }
  end

  # ============================================
  # action_is_optimistic?/1
  # ============================================

  describe "action_is_optimistic?/1" do
    test "true when action has sets" do
      a = action(sets: [%Lavash.Actions.Set{field: :count, value: 1}])
      assert ActionJs.action_is_optimistic?(a)
    end

    test "true when action has updates" do
      a = action(updates: [%Lavash.Actions.Update{field: :count, fun: &(&1 + 1)}])
      assert ActionJs.action_is_optimistic?(a)
    end

    test "true when action has map_bys" do
      a = action(map_bys: [%{field: :items}])
      assert ActionJs.action_is_optimistic?(a)
    end

    test "true when action has runs and reads" do
      a = action(runs: [%{fun: :some_fun}], reads: [:product])
      assert ActionJs.action_is_optimistic?(a)
    end

    test "false when action has only runs (no reads)" do
      a = action(runs: [%{fun: :some_fun}])
      refute ActionJs.action_is_optimistic?(a)
    end

    test "false when action has only effects" do
      a = action(effects: [%{fun: fn _ -> :ok end}])
      refute ActionJs.action_is_optimistic?(a)
    end

    test "false for empty action" do
      refute ActionJs.action_is_optimistic?(action())
    end
  end

  # ============================================
  # analyze_value/1
  # ============================================

  describe "analyze_value/1" do
    test "returns {:rx, source} for Rx struct" do
      rx = %Lavash.Rx{source: "@count + 1", ast: nil, deps: []}
      assert {:rx, "@count + 1"} = ActionJs.analyze_value(rx)
    end

    test "returns {:literal, value} for integer" do
      assert {:literal, 42} = ActionJs.analyze_value(42)
    end

    test "returns {:literal, value} for string" do
      assert {:literal, "hello"} = ActionJs.analyze_value("hello")
    end

    test "returns {:literal, value} for boolean" do
      assert {:literal, true} = ActionJs.analyze_value(true)
    end

    test "returns {:literal, value} for atom" do
      assert {:literal, :foo} = ActionJs.analyze_value(:foo)
    end

    test "returns {:literal, value} for list of literals" do
      assert {:literal, [1, "a", true]} = ActionJs.analyze_value([1, "a", true])
    end

    test "returns :unknown for list with non-literals" do
      assert :unknown = ActionJs.analyze_value([%{complex: true}])
    end

    test "returns :from_params_value for param accessor function" do
      fun = fn %{params: params} -> params[:value] || params.value end
      assert :from_params_value = ActionJs.analyze_value(fun)
    end

    test "returns :unknown for arbitrary function" do
      fun = fn _ -> :something_else end
      assert :unknown = ActionJs.analyze_value(fun)
    end

    test "returns :unknown for map" do
      assert :unknown = ActionJs.analyze_value(%{key: "value"})
    end
  end

  # ============================================
  # analyze_update_function/1
  # ============================================

  describe "analyze_update_function/1" do
    test "detects increment by 1" do
      assert {:increment, 1} = ActionJs.analyze_update_function(&(&1 + 1))
    end

    test "detects increment by arbitrary n" do
      assert {:increment, 5} = ActionJs.analyze_update_function(&(&1 + 5))
    end

    test "detects decrement by 1" do
      assert {:decrement, 1} = ActionJs.analyze_update_function(&(&1 - 1))
    end

    test "detects decrement by arbitrary n" do
      assert {:decrement, 3} = ActionJs.analyze_update_function(&(&1 - 3))
    end

    test "returns :unknown for non-linear function" do
      assert :unknown = ActionJs.analyze_update_function(&(&1 * 2))
    end

    test "returns :unknown for non-function" do
      assert :unknown = ActionJs.analyze_update_function("not a function")
    end
  end

  # ============================================
  # generate_update_js/1
  # ============================================

  describe "generate_update_js/1" do
    test "generates JS for increment" do
      update = %Lavash.Actions.Update{field: :count, fun: &(&1 + 1)}
      assert "count: state.count + 1" = ActionJs.generate_update_js(update)
    end

    test "generates JS for decrement" do
      update = %Lavash.Actions.Update{field: :count, fun: &(&1 - 3)}
      assert "count: state.count - 3" = ActionJs.generate_update_js(update)
    end

    test "returns nil for unknown pattern" do
      update = %Lavash.Actions.Update{field: :count, fun: &(&1 * 2)}
      assert is_nil(ActionJs.generate_update_js(update))
    end
  end

  # ============================================
  # normalize_dep_to_string/1
  # ============================================

  describe "normalize_dep_to_string/1" do
    test "converts atom to string" do
      assert "count" = ActionJs.normalize_dep_to_string(:count)
    end

    test "converts path dep to root string" do
      assert "params" = ActionJs.normalize_dep_to_string({:path, :params, ["name"]})
    end
  end
end
