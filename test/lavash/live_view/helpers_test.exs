defmodule Lavash.LiveView.HelpersTest do
  use ExUnit.Case, async: true

  alias Lavash.LiveView.Helpers

  # Mock module with optimistic fields and calculations
  defmodule MockLiveView do
    def __lavash__(:optimistic_fields) do
      [
        %Lavash.State.Field{name: :count, type: :integer, from: :url, default: 0, optimistic: true},
        %Lavash.State.Field{name: :name, type: :string, from: :ephemeral, default: "", optimistic: true}
      ]
    end

    def __lavash__(:optimistic_derives), do: []
    def __lavash__(:forms), do: []

    def __lavash_calculations__, do: []
  end

  defmodule MockWithDerives do
    def __lavash__(:optimistic_fields), do: []

    def __lavash__(:optimistic_derives) do
      [%{name: :doubled, optimistic: true}]
    end

    def __lavash__(:forms), do: []
    def __lavash_calculations__, do: []
  end

  defmodule MockWithCalcs do
    def __lavash__(:optimistic_fields) do
      [%Lavash.State.Field{name: :count, type: :integer, from: :ephemeral, default: 0, optimistic: true}]
    end

    def __lavash__(:optimistic_derives), do: []
    def __lavash__(:forms), do: []

    def __lavash_calculations__ do
      state_var = Macro.var(:state, nil)
      ast = quote do: Map.get(unquote(state_var), :count) * 2

      [{:doubled, "@count * 2", ast, [:count], true, false, []}]
    end
  end

  defmodule MockWithNonOptimisticCalc do
    def __lavash__(:optimistic_fields) do
      [%Lavash.State.Field{name: :count, type: :integer, from: :ephemeral, default: 0, optimistic: true}]
    end

    def __lavash__(:optimistic_derives), do: []
    def __lavash__(:forms), do: []

    def __lavash_calculations__ do
      [{:total, "Decimal.to_string(@count)", nil, [:count], false, false, []}]
    end
  end

  defmodule MockEmpty do
    def __lavash__(:optimistic_fields), do: []
    def __lavash__(:optimistic_derives), do: []
    def __lavash__(:forms), do: []
    def __lavash_calculations__, do: []
  end

  # ============================================
  # optimistic_state/2
  # ============================================

  describe "optimistic_state/2" do
    test "collects optimistic state fields into map" do
      assigns = %{count: 5, name: "hello", other: "ignored"}
      result = Helpers.optimistic_state(MockLiveView, assigns)

      assert result[:count] == 5
      assert result[:name] == "hello"
      refute Map.has_key?(result, :other)
    end

    test "collects optimistic derives" do
      assigns = %{doubled: 10}
      result = Helpers.optimistic_state(MockWithDerives, assigns)

      assert result[:doubled] == 10
    end

    test "unwraps AsyncResult ok" do
      assigns = %{doubled: %Phoenix.LiveView.AsyncResult{ok?: true, result: 42, loading: nil}}
      result = Helpers.optimistic_state(MockWithDerives, assigns)

      assert result[:doubled] == 42
    end

    test "returns nil for loading AsyncResult" do
      assigns = %{doubled: %Phoenix.LiveView.AsyncResult{ok?: false, result: nil, loading: [self()]}}
      result = Helpers.optimistic_state(MockWithDerives, assigns)

      assert result[:doubled] == nil
    end

    test "evaluates optimistic calculations from state" do
      assigns = %{count: 7}
      result = Helpers.optimistic_state(MockWithCalcs, assigns)

      assert result[:count] == 7
      assert result[:doubled] == 14
    end

    test "skips non-optimistic calculations" do
      assigns = %{count: 5}
      result = Helpers.optimistic_state(MockWithNonOptimisticCalc, assigns)

      assert result[:count] == 5
      refute Map.has_key?(result, :total)
    end

    test "returns empty map when no optimistic fields" do
      result = Helpers.optimistic_state(MockEmpty, %{})
      assert result == %{}
    end
  end

  # ============================================
  # component state management
  # ============================================

  describe "component state management" do
    test "put/get round-trip via process dict" do
      states = %{counter: %{count: 5}}
      Helpers.put_component_states(states)
      assert Helpers.get_component_states() == states
    after
      Process.delete(:__lavash_component_states__)
    end

    test "returns empty map when nothing stored" do
      Process.delete(:__lavash_component_states__)
      assert Helpers.get_component_states() == %{}
    end
  end
end
