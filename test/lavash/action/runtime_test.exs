defmodule Lavash.Action.RuntimeTest do
  use ExUnit.Case, async: true

  alias Lavash.Action.Runtime
  alias Lavash.Socket, as: LSocket

  defp bare_socket do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}},
      private: %{}
    }
  end

  defp socket_with_state(fields) do
    socket = bare_socket() |> LSocket.init()

    Enum.reduce(fields, socket, fn {k, v}, s ->
      LSocket.put_state(s, k, v)
    end)
    |> LSocket.clear_dirty()
  end

  # Mock module for apply_sets (needs __lavash__(:states))
  defmodule MockModule do
    def __lavash__(:states) do
      [
        %Lavash.State.Field{name: :count, type: :integer, from: :ephemeral, default: 0},
        %Lavash.State.Field{name: :name, type: :string, from: :ephemeral, default: ""},
        %Lavash.State.Field{name: :enabled, type: :boolean, from: :ephemeral, default: false}
      ]
    end
  end

  defmodule NoTypesModule do
    def __lavash__(:states), do: []
  end

  # ============================================
  # guards_pass?/3
  # ============================================

  describe "guards_pass?/3" do
    test "returns true when all guard fields are true" do
      socket = socket_with_state(enabled: true, ready: true)
      assert Runtime.guards_pass?(socket, nil, [:enabled, :ready])
    end

    test "returns false when any guard field is false" do
      socket = socket_with_state(enabled: true, ready: false)
      refute Runtime.guards_pass?(socket, nil, [:enabled, :ready])
    end

    test "returns false when guard field is nil" do
      socket = socket_with_state(enabled: nil)
      refute Runtime.guards_pass?(socket, nil, [:enabled])
    end

    test "returns true for empty guard list" do
      socket = socket_with_state([])
      assert Runtime.guards_pass?(socket, nil, [])
    end
  end

  # ============================================
  # apply_sets/4
  # ============================================

  describe "apply_sets/4" do
    test "sets field to literal value" do
      socket = socket_with_state(count: 0)
      set = %Lavash.Actions.Set{field: :count, value: 42}

      result = Runtime.apply_sets(socket, [set], %{}, MockModule)
      assert LSocket.get_state(result, :count) == 42
    end

    test "sets field to value from Rx expression" do
      # rx() transforms @count to Map.get(state, :count) where state is an
      # unhygienic variable bound by Code.eval_quoted in evaluate_set_value
      state_var = Macro.var(:state, nil)
      ast = quote do: Map.get(unquote(state_var), :count) + 1
      rx = %Lavash.Rx{ast: ast, source: "@count + 1", deps: [:count]}
      socket = socket_with_state(count: 5)
      set = %Lavash.Actions.Set{field: :count, value: rx}

      result = Runtime.apply_sets(socket, [set], %{}, MockModule)
      assert LSocket.get_state(result, :count) == 6
    end

    test "sets field to value from function capture" do
      socket = socket_with_state(count: 0)
      set = %Lavash.Actions.Set{field: :count, value: fn %{params: p} -> p[:amount] end}

      result = Runtime.apply_sets(socket, [set], %{amount: 99}, MockModule)
      assert LSocket.get_state(result, :count) == 99
    end

    test "coerces string to integer when field type is :integer" do
      socket = socket_with_state(count: 0)
      set = %Lavash.Actions.Set{field: :count, value: "42"}

      result = Runtime.apply_sets(socket, [set], %{}, MockModule)
      assert LSocket.get_state(result, :count) == 42
    end

    test "applies multiple sets sequentially" do
      socket = socket_with_state(count: 0, name: "")

      sets = [
        %Lavash.Actions.Set{field: :count, value: 10},
        %Lavash.Actions.Set{field: :name, value: "hello"}
      ]

      result = Runtime.apply_sets(socket, sets, %{}, MockModule)
      assert LSocket.get_state(result, :count) == 10
      assert LSocket.get_state(result, :name) == "hello"
    end
  end

  # ============================================
  # apply_effects/3
  # ============================================

  describe "apply_effects/3" do
    test "executes effect function with current state" do
      test_pid = self()
      socket = socket_with_state(count: 42)

      effect = %Lavash.Actions.Effect{
        fun: fn state -> send(test_pid, {:effect, state[:count]}) end
      }

      Runtime.apply_effects(socket, [effect], %{})
      assert_receive {:effect, 42}
    end

    test "returns socket unchanged" do
      socket = socket_with_state(count: 42)
      effect = %Lavash.Actions.Effect{fun: fn _state -> :ok end}

      result = Runtime.apply_effects(socket, [effect], %{})
      assert LSocket.get_state(result, :count) == 42
    end
  end

  # ============================================
  # coerce_value/2
  # ============================================

  describe "coerce_value/2" do
    test "returns value unchanged when state_field is nil" do
      assert Runtime.coerce_value("hello", nil) == "hello"
    end

    test "returns nil when value is nil" do
      field = %{type: :integer}
      assert Runtime.coerce_value(nil, field) == nil
    end

    test "returns nil for empty string on non-string type" do
      field = %{type: :integer}
      assert Runtime.coerce_value("", field) == nil
    end

    test "parses string via Type.parse" do
      field = %{type: :integer}
      assert Runtime.coerce_value("42", field) == 42
    end

    test "returns original value when parse fails" do
      field = %{type: :integer}
      assert Runtime.coerce_value("not_a_number", field) == "not_a_number"
    end

    test "returns non-string value unchanged" do
      field = %{type: :integer}
      assert Runtime.coerce_value(42, field) == 42
    end
  end

  # ============================================
  # build_params/2
  # ============================================

  describe "apply_runs/4" do
    # Regression for u2i/lavash#12 — `run fn` bodies should see calculated
    # fields, not just declared state. Building assigns from `LSocket.state`
    # (which skips :derived_field_names) made `reads [:my_calc]` raise
    # KeyError at runtime. Fix uses `LSocket.full_state` so calculations
    # are visible alongside state.
    test "assigns map passed to run fn includes derived (calculated) fields" do
      socket =
        socket_with_state(count: 5)
        |> LSocket.put_derived(:doubled, 10)

      run = %Lavash.Actions.Run{
        fun:
          quote do
            fn assigns ->
              # Body reads both a state field and a derived field, then
              # writes the sum back. If derived isn't in assigns this
              # raises KeyError on `assigns.doubled`.
              assign(assigns, :sum, assigns.count + assigns.doubled)
            end
          end
      }

      result = Runtime.apply_runs(socket, [run], %{}, NoTypesModule)

      assert LSocket.get_state(result, :sum) == 15
    end

    test "params are merged into the assigns map alongside state and derived" do
      socket =
        socket_with_state(base: 1)
        |> LSocket.put_derived(:bonus, 100)

      run = %Lavash.Actions.Run{
        fun:
          quote do
            fn assigns ->
              total = assigns.base + assigns.bonus + assigns.delta
              assign(assigns, :total, total)
            end
          end
      }

      result = Runtime.apply_runs(socket, [run], %{delta: 5}, NoTypesModule)

      assert LSocket.get_state(result, :total) == 106
    end
  end

  describe "build_params/2" do
    test "extracts named params from event payload" do
      result = Runtime.build_params([:item_id], %{"item_id" => "abc"})
      assert result == %{item_id: "abc"}
    end

    test "falls back to 'value' key when named param missing" do
      result = Runtime.build_params([:amount], %{"value" => "10"})
      assert result == %{amount: "10"}
    end

    test "returns empty map for nil param spec" do
      assert Runtime.build_params(nil, %{"foo" => "bar"}) == %{}
    end

    test "handles multiple params" do
      result = Runtime.build_params([:a, :b], %{"a" => "1", "b" => "2"})
      assert result == %{a: "1", b: "2"}
    end
  end
end
