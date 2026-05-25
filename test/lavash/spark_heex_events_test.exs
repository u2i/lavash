defmodule Lavash.SparkHeexEventsTest do
  @moduledoc """
  Demonstrates `ValidateEvents`: phx-click="event_name" in the template must
  match a declared `action :event_name` in the DSL. The validation walks
  the parsed Phoenix.LiveView.TagEngine.Parser tree, not the source string,
  so it only flags literal event names (dynamic `phx-click={...}` is
  intentionally out of scope).
  """
  use ExUnit.Case, async: true

  defmodule GoodCounter do
    use Lavash.SparkHeex

    state :count, :integer, default: 0

    action :inc
    action :set_count, args: [:value]

    template do
      ~H"""
      <button phx-click="inc">+1</button>
      <form phx-submit="set_count">
        <input name="value" />
      </form>
      <span>{@count}</span>
      """
    end
  end

  defmodule DynamicHandler do
    use Lavash.SparkHeex

    state :handler_name, :atom, default: "noop"

    template do
      ~H"""
      <button phx-click={@handler_name}>click</button>
      """
    end
  end

  test "compiles when every literal phx-* event name matches a declared action" do
    out =
      GoodCounter.render(%{})
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()

    assert out =~ ~s|phx-click="inc"|
    assert out =~ ~s|phx-submit="set_count"|
  end

  test "dynamic event names (phx-click={@x}) are not validated" do
    # Just compiling DynamicHandler without raising is the assertion.
    assert is_atom(DynamicHandler)
  end

  test "raises a DslError naming the undeclared event handler" do
    err =
      assert_raise Spark.Error.DslError, fn ->
        Code.compile_string("""
        defmodule Lavash.SparkHeexEventsTest.Broken do
          use Lavash.SparkHeex

          state :count, :integer, default: 0
          action :inc

          template do
            ~H\"\"\"
            <button phx-click="inc">+1</button>
            <button phx-click="nope">??</button>
            \"\"\"
          end
        end
        """)
      end

    message = Exception.message(err)
    assert message =~ "undeclared event handler"
    assert message =~ "nope"
    # Mentions a declared action so the user can see the candidates
    assert message =~ "inc"
    # Includes a file/line-ish location
    assert message =~ ~r/:\d+:\d+/
  end
end
