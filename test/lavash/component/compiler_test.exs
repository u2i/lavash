defmodule Lavash.Component.CompilerTest do
  use ExUnit.Case, async: true

  alias Lavash.Component.Compiler

  # ============================================
  # Mock modules
  # ============================================

  # Component with optimistic state, props, and a calculation that references a prop
  defmodule WithReferencedProp do
    def __lavash__(:optimistic_fields) do
      [
        %Lavash.State.Field{
          name: :count,
          type: :integer,
          from: :ephemeral,
          default: 0,
          optimistic: true
        }
      ]
    end

    def __lavash__(:props) do
      [
        %Lavash.Component.Prop{name: :multiplier, type: :integer, default: 1},
        %Lavash.Component.Prop{name: :product, type: :map, default: nil}
      ]
    end

    def __lavash__(:actions), do: []

    def __lavash_calculations__ do
      # doubled depends on :count and :multiplier
      state_var = Macro.var(:state, nil)

      ast =
        quote do: Map.get(unquote(state_var), :count) * Map.get(unquote(state_var), :multiplier)

      [{:doubled, "@count * @multiplier", ast, [:count, :multiplier], true, false, []}]
    end
  end

  # Component with no calculations or actions — no props should be included
  defmodule WithUnreferencedProp do
    def __lavash__(:optimistic_fields) do
      [
        %Lavash.State.Field{
          name: :expanded,
          type: :boolean,
          from: :ephemeral,
          default: false,
          optimistic: true
        }
      ]
    end

    def __lavash__(:props) do
      [%Lavash.Component.Prop{name: :product, type: :map, default: nil}]
    end

    def __lavash__(:actions), do: []
    def __lavash_calculations__, do: []
  end

  # Component with action that references a prop via rx
  defmodule WithActionPropDep do
    def __lavash__(:optimistic_fields) do
      [
        %Lavash.State.Field{
          name: :total,
          type: :integer,
          from: :ephemeral,
          default: 0,
          optimistic: true
        }
      ]
    end

    def __lavash__(:props) do
      [%Lavash.Component.Prop{name: :price, type: :integer, default: 0}]
    end

    def __lavash__(:actions) do
      [
        %Lavash.Actions.Action{
          name: :compute,
          params: [],
          when: [],
          sets: [
            %Lavash.Actions.Set{
              field: :total,
              value: %Lavash.Rx{source: "@price * 2", ast: nil, deps: [:price]}
            }
          ],
          updates: [],
          effects: [],
          submits: [],
          navigates: [],
          flashes: [],
          invokes: []
        }
      ]
    end

    def __lavash_calculations__, do: []
  end

  # Component with no lavash functions at all
  defmodule NoLavash do
  end

  # ============================================
  # build_client_state/2
  # ============================================

  describe "build_client_state/2" do
    test "includes optimistic state fields" do
      assigns = %{count: 5, multiplier: 3, product: %{name: "Test"}}
      result = Compiler.build_client_state(WithReferencedProp, assigns)

      assert result[:count] == 5
    end

    test "includes props referenced by calculations" do
      assigns = %{count: 5, multiplier: 3, product: %{name: "Test"}}
      result = Compiler.build_client_state(WithReferencedProp, assigns)

      assert result[:multiplier] == 3
    end

    test "excludes props not referenced by JS" do
      assigns = %{count: 5, multiplier: 3, product: %{name: "Test"}}
      result = Compiler.build_client_state(WithReferencedProp, assigns)

      refute Map.has_key?(result, :product)
    end

    test "excludes all props when no calculations or actions reference them" do
      assigns = %{expanded: true, product: %{name: "Test", price: 10}}
      result = Compiler.build_client_state(WithUnreferencedProp, assigns)

      assert result[:expanded] == true
      refute Map.has_key?(result, :product)
    end

    test "includes props referenced by action rx deps" do
      assigns = %{total: 0, price: 25}
      result = Compiler.build_client_state(WithActionPropDep, assigns)

      assert result[:price] == 25
    end

    test "uses prop default when assign is missing" do
      assigns = %{count: 0}
      result = Compiler.build_client_state(WithReferencedProp, assigns)

      # multiplier default is 1
      assert result[:multiplier] == 1
    end

    test "returns empty map for module without lavash functions" do
      result = Compiler.build_client_state(NoLavash, %{})
      assert result == %{}
    end
  end
end
