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
      effects: Keyword.get(opts, :effects, []),
      submits: Keyword.get(opts, :submits, []),
      navigates: Keyword.get(opts, :navigates, []),
      flashes: Keyword.get(opts, :flashes, []),
      invokes: Keyword.get(opts, :invokes, []),
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
