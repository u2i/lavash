defmodule Lavash.BindingValidationTest do
  @moduledoc """
  `from: :bound` semantics (issue #87): a component's bindable surface
  is exactly its `from: :bound` state fields.

  - unbound, a :bound field falls back to ephemeral-with-default
  - bind sites targeting anything else (props, :ephemeral fields,
    unknown names) are compile errors when the module is a literal, and
    runtime errors otherwise
  - the parent side must be writable, type-compatible, and
    client-visible when the child predicts optimistically
  """
  use ExUnit.Case, async: true

  alias Lavash.Binding.Validation

  defmodule Bindable do
    @moduledoc false
    use Lavash.Component

    prop :label, :string, default: "x"

    state :value, :integer, from: :bound, default: 7, optimistic: true
    state :internal, :integer, from: :ephemeral, default: 0

    template do
      ~H"""
      <div><span id={"val-" <> @id}>{@value}</span></div>
      """
    end
  end

  describe "introspection" do
    test "bound fields hydrate like ephemeral fields but are the only bindable surface" do
      assert [%{name: :value, from: :bound}] = Bindable.__lavash__(:bound_fields)

      ephemeral_names = Bindable.__lavash__(:ephemeral_fields) |> Enum.map(& &1.name)
      assert :value in ephemeral_names
      assert :internal in ephemeral_names
    end

    test "LiveViews expose an empty bindable surface" do
      defmodule PlainHost do
        @moduledoc false
        use Lavash.LiveView

        state :x, :integer, from: :ephemeral, default: 0

        template do
          ~H"""
          <div>{@x}</div>
          """
        end
      end

      assert PlainHost.__lavash__(:bound_fields) == []
    end
  end

  describe "validate_child_side/2" do
    test "accepts a from: :bound field" do
      assert :ok = Validation.validate_child_side(Bindable, value: :anything)
    end

    test "rejects a prop" do
      assert {:error, msg} = Validation.validate_child_side(Bindable, label: :anything)
      assert msg =~ "it is a prop"
      assert msg =~ "from: :bound"
    end

    test "rejects a non-bound state field, naming its declared source" do
      assert {:error, msg} = Validation.validate_child_side(Bindable, internal: :anything)
      assert msg =~ "from: :ephemeral"
      assert msg =~ "Only `from: :bound`"
    end

    test "rejects an unknown field and lists the bindable surface" do
      assert {:error, msg} = Validation.validate_child_side(Bindable, nope: :anything)
      assert msg =~ "no such state field"
      assert msg =~ ":value"
    end

    test "skips modules without lavash introspection" do
      assert :ok = Validation.validate_child_side(String, anything: :anything)
    end
  end

  describe "validate_parent_side/3" do
    defp metadata(overrides \\ %{}) do
      Map.merge(
        %{
          caller_module: FakeParent,
          all_state_fields: %{
            counter: %Lavash.State.Field{name: :counter, type: :integer, optimistic: true},
            title: %Lavash.State.Field{name: :title, type: :string, optimistic: true},
            hidden: %Lavash.State.Field{name: :hidden, type: :integer},
            set_backed: %Lavash.State.Field{name: :set_backed, type: :integer, setter: true}
          },
          optimistic_fields: %{
            counter: %{optimistic: true},
            title: %{optimistic: true}
          },
          calculation_names: MapSet.new([:derived])
        },
        overrides
      )
    end

    test "accepts a matching optimistic state field" do
      assert :ok = Validation.validate_parent_side(Bindable, [value: :counter], metadata())
    end

    test "rejects binding to a calculation" do
      assert {:error, msg} =
               Validation.validate_parent_side(Bindable, [value: :derived], metadata())

      assert msg =~ "it is a calculation"
    end

    test "rejects a concrete type mismatch" do
      assert {:error, msg} =
               Validation.validate_parent_side(Bindable, [value: :title], metadata())

      assert msg =~ "type mismatch"
    end

    test "rejects an optimistic child bound to a non-client-visible parent field" do
      assert {:error, msg} =
               Validation.validate_parent_side(Bindable, [value: :hidden], metadata())

      assert msg =~ "not client-visible"
    end

    test "a setter-backed parent field counts as client-visible" do
      assert :ok = Validation.validate_parent_side(Bindable, [value: :set_backed], metadata())
    end

    test "unknown parent fields fall through (the transformer's warning path owns those)" do
      assert :ok = Validation.validate_parent_side(Bindable, [value: :who_knows], metadata())
    end
  end

  describe "compile-time enforcement" do
    test "a literal bind targeting a non-bound field is a CompileError" do
      src = """
      defmodule Lavash.BindingValidationTest.BadHost do
        use Lavash.LiveView
        import Lavash.LiveView.Helpers, only: [lavash_component: 1]

        state :counter, :integer, from: :ephemeral, default: 0, optimistic: true

        template do
          ~H\"\"\"
          <div>
            <.lavash_component
              module={Lavash.BindingValidationTest.Bindable}
              id="c"
              bind={[internal: :counter]}
            />
          </div>
          \"\"\"
        end
      end
      """

      err = assert_raise Spark.Error.DslError, fn -> Code.compile_string(src, "nofile") end
      assert Exception.message(err) =~ "from: :ephemeral"
    end

    test "a literal bind to a parent calculation is a CompileError" do
      src = """
      defmodule Lavash.BindingValidationTest.CalcHost do
        use Lavash.LiveView
        import Lavash.LiveView.Helpers, only: [lavash_component: 1]

        state :counter, :integer, from: :ephemeral, default: 0, optimistic: true
        calculate :doubled, rx(@counter * 2)

        template do
          ~H\"\"\"
          <div>
            <.lavash_component
              module={Lavash.BindingValidationTest.Bindable}
              id="c"
              bind={[value: :doubled]}
            />
          </div>
          \"\"\"
        end
      end
      """

      err = assert_raise Spark.Error.DslError, fn -> Code.compile_string(src, "nofile") end
      assert Exception.message(err) =~ "it is a calculation"
    end

    test "a valid literal bind compiles" do
      src = """
      defmodule Lavash.BindingValidationTest.GoodHost do
        use Lavash.LiveView
        import Lavash.LiveView.Helpers, only: [lavash_component: 1]

        state :counter, :integer, from: :ephemeral, default: 0, optimistic: true

        template do
          ~H\"\"\"
          <div>
            <.lavash_component
              module={Lavash.BindingValidationTest.Bindable}
              id="c"
              bind={[value: :counter]}
            />
          </div>
          \"\"\"
        end
      end
      """

      assert [{_mod, _} | _] = Code.compile_string(src, "nofile")
    end
  end
end
