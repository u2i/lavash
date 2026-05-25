defmodule Lavash.SparkHeexTest do
  @moduledoc """
  Spike test: see `Lavash.SparkHeex` for the design notes.
  """
  use ExUnit.Case, async: true

  defmodule Counter do
    use Lavash.SparkHeex

    state :count, :integer, default: 0
    state :label, :atom, default: "Count"

    template do
      ~H"""
      <button phx-click="inc">{@label}: {@count}</button>
      """
    end
  end

  defp render_to_string(mod, assigns) do
    mod.render(assigns)
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  test "captures the raw template source as DSL-level data" do
    assert Counter.__lavash_heex_template_source__() =~ "{@label}: {@count}"
  end

  test "render/1 returns a Phoenix.LiveView.Rendered with provided assigns" do
    out = render_to_string(Counter, %{count: 5, label: "Tally"})
    assert out =~ ~s|<button phx-click="inc">Tally: 5</button>|
  end

  test "render/1 falls back to declared state defaults" do
    out = render_to_string(Counter, %{})
    assert out =~ ~s|<button phx-click="inc">Count: 0</button>|
  end

  test "DSL-level error when template references an undeclared state field" do
    err =
      assert_raise Spark.Error.DslError, fn ->
        Code.compile_string("""
        defmodule Lavash.SparkHeexTest.Broken do
          use Lavash.SparkHeex
          state :count, :integer, default: 0
          template do
            ~H\"\"\"
            <div>{@count} / {@nope}</div>
            \"\"\"
          end
        end
        """)
      end

    assert Exception.message(err) =~ "undeclared state field"
    assert Exception.message(err) =~ "@nope"
  end
end
