defmodule Lavash.Action.HelperRefsTest do
  @moduledoc """
  Issue #3 regression: helper functions called inside `run fn assigns -> ... end`
  should be tracked by the compiler so they don't surface as "unused" — which
  breaks builds running with `--warnings-as-errors`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "private helper called only from a run fn is not flagged as unused" do
    source = """
    defmodule Lavash.Action.HelperRefsTest.UsesPrivateHelper do
      use Lavash.LiveView

      state :submitted, :boolean, default: false

      actions do
        action :submit do
          run fn assigns ->
            _ = enqueue_commit_job(assigns)
            Phoenix.Component.assign(assigns, :submitted, true)
          end
        end
      end

      defp enqueue_commit_job(_assigns), do: :ok

      def render(assigns) do
        ~H\"<div>{@submitted}</div>\"
      end
    end
    """

    warnings =
      capture_io(:stderr, fn ->
        Code.compile_string(source, "nofile")
      end)

    refute warnings =~ "enqueue_commit_job/1 is unused",
           "expected the compiler to see the helper reference inside the run fn, got:\n#{warnings}"
  after
    :code.purge(Lavash.Action.HelperRefsTest.UsesPrivateHelper)
    :code.delete(Lavash.Action.HelperRefsTest.UsesPrivateHelper)
  end

  test "multiple private helpers from a single run fn are tracked" do
    source = """
    defmodule Lavash.Action.HelperRefsTest.MultipleHelpers do
      use Lavash.LiveView

      state :submitted, :boolean, default: false

      actions do
        action :submit do
          run fn assigns ->
            assigns
            |> maybe_put(:a, 1)
            |> maybe_put(:b, nil)
            |> trim_or_nil()
          end
        end
      end

      defp maybe_put(map, _k, nil), do: map
      defp maybe_put(map, k, v), do: Map.put(map, k, v)
      defp trim_or_nil(map), do: map

      def render(assigns) do
        ~H\"<div>{@submitted}</div>\"
      end
    end
    """

    warnings =
      capture_io(:stderr, fn ->
        Code.compile_string(source, "nofile")
      end)

    refute warnings =~ "maybe_put/3 is unused", "got:\n#{warnings}"
    refute warnings =~ "trim_or_nil/1 is unused", "got:\n#{warnings}"
  after
    :code.purge(Lavash.Action.HelperRefsTest.MultipleHelpers)
    :code.delete(Lavash.Action.HelperRefsTest.MultipleHelpers)
  end
end
