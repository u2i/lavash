defmodule Lavash.SparkHeexActionParamsTest do
  @moduledoc """
  `ValidateActionParams`: each element with a literal `phx-click`-style
  attribute must carry exactly the `phx-value-*` keys declared on the
  matching action.

  Composes with `ValidateEvents` (which catches unknown event names) by
  scoping its checks to elements whose event name *does* match a declared
  action. Anything dynamic is skipped.
  """
  use ExUnit.Case, async: true

  defmodule Happy do
    use Lavash.SparkHeex

    state :count, :integer, default: 0

    action :set_count, args: [:amount]
    action :reset

    template do
      ~H"""
      <button phx-click="set_count" phx-value-amount="5">+5</button>
      <button phx-click="reset">reset</button>
      <span>{@count}</span>
      """
    end
  end

  defmodule DynamicValueOk do
    use Lavash.SparkHeex

    state :next, :integer, default: 1

    action :set_count, args: [:amount]

    template do
      ~H"""
      <button phx-click="set_count" phx-value-amount={@next}>+next</button>
      """
    end
  end

  defmodule DynamicEventNameSkipped do
    use Lavash.SparkHeex

    state :handler, :atom, default: "noop"

    action :set_count, args: [:amount]

    template do
      ~H"""
      <button phx-click={@handler} phx-value-bogus="x">click</button>
      """
    end
  end

  defmodule NoArgs do
    use Lavash.SparkHeex

    state :count, :integer, default: 0

    action :inc

    template do
      ~H"""
      <button phx-click="inc">+1</button>
      """
    end
  end

  defmodule SubmitChangeForm do
    use Lavash.SparkHeex

    state :name, :atom, default: ""

    action :save, args: [:name]
    action :validate, args: [:name]

    template do
      ~H"""
      <form phx-submit="save" phx-value-name="alpha">
        <input phx-change="validate" phx-value-name="beta" />
      </form>
      """
    end
  end

  test "compiles when phx-value-* keys exactly match the declared args" do
    out =
      Happy.render(%{})
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()

    assert out =~ ~s|phx-click="set_count"|
    assert out =~ ~s|phx-value-amount="5"|
  end

  test "compiles when an action has args: [] and the element has no phx-value-*" do
    out =
      NoArgs.render(%{})
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()

    assert out =~ ~s|phx-click="inc"|
  end

  test "compiles when phx-value-* uses a dynamic value — only the key is checked" do
    out =
      DynamicValueOk.render(%{})
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()

    assert out =~ ~s|phx-click="set_count"|
    assert out =~ ~s|phx-value-amount="1"|
  end

  test "compiles when the event name is dynamic (no static action to validate against)" do
    # Just compiling without raising is the assertion. The phx-value-bogus
    # would be a problem if we tried to validate it, but the dynamic event
    # name means we can't know which action it routes to.
    assert is_atom(DynamicEventNameSkipped)
  end

  test "phx-submit and phx-change validate independently per element" do
    out =
      SubmitChangeForm.render(%{})
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()

    assert out =~ ~s|phx-submit="save"|
    assert out =~ ~s|phx-change="validate"|
  end

  test "DslError on typo'd phx-value-* key" do
    err =
      assert_raise Spark.Error.DslError, fn ->
        Code.compile_string("""
        defmodule Lavash.SparkHeexActionParamsTest.TypoKey do
          use Lavash.SparkHeex

          action :set_count, args: [:amount]

          template do
            ~H\"\"\"
            <button phx-click="set_count" phx-value-mount="5">typo</button>
            \"\"\"
          end
        end
        """)
      end

    message = Exception.message(err)
    assert message =~ "set_count"
    assert message =~ "phx-value-mount"
    assert message =~ "unknown"
    # Action's actual declared args appear so the user can spot the typo
    assert message =~ "amount"
    # File/line location
    assert message =~ ~r/:\d+:\d+/
  end

  test "DslError when a required arg is missing on the element" do
    err =
      assert_raise Spark.Error.DslError, fn ->
        Code.compile_string("""
        defmodule Lavash.SparkHeexActionParamsTest.MissingArg do
          use Lavash.SparkHeex

          action :set_count, args: [:amount]

          template do
            ~H\"\"\"
            <button phx-click="set_count">forgot arg</button>
            \"\"\"
          end
        end
        """)
      end

    message = Exception.message(err)
    assert message =~ "set_count"
    assert message =~ "missing"
    assert message =~ "phx-value-amount"
  end

  test "different elements with different events validate independently" do
    # One element OK, another element bad — should still raise.
    err =
      assert_raise Spark.Error.DslError, fn ->
        Code.compile_string("""
        defmodule Lavash.SparkHeexActionParamsTest.MixedElements do
          use Lavash.SparkHeex

          action :ok_event, args: [:foo]
          action :bad_event, args: [:bar]

          template do
            ~H\"\"\"
            <button phx-click="ok_event" phx-value-foo="1">OK</button>
            <button phx-click="bad_event" phx-value-wrong="1">bad</button>
            \"\"\"
          end
        end
        """)
      end

    message = Exception.message(err)
    assert message =~ "bad_event"
    assert message =~ "phx-value-wrong"
    # The OK element's event name should not appear in the error
    refute message =~ "ok_event"
  end

  test "an undeclared event name is left for ValidateEvents (not double-reported here)" do
    err =
      assert_raise Spark.Error.DslError, fn ->
        Code.compile_string("""
        defmodule Lavash.SparkHeexActionParamsTest.UndeclaredEvent do
          use Lavash.SparkHeex

          template do
            ~H\"\"\"
            <button phx-click="nope" phx-value-anything="x">??</button>
            \"\"\"
          end
        end
        """)
      end

    # The error comes from ValidateEvents (undeclared event handler), not
    # from ValidateActionParams.
    message = Exception.message(err)
    assert message =~ "undeclared event handler"
    assert message =~ "nope"
  end
end
