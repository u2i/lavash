defmodule Lavash.Action.HelperRefsTest do
  @moduledoc """
  Issue #3 regression: helper functions called inside `run fn socket -> ... end`
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
          run fn socket ->
            _ = enqueue_commit_job(socket)
            Phoenix.Component.assign(socket, :submitted, true)
          end
        end
      end

      defp enqueue_commit_job(_socket), do: :ok

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
          run fn socket ->
            socket
            |> maybe_put(:a, 1)
            |> maybe_put(:b, nil)
            |> trim_or_nil()
          end
        end
      end

      defp maybe_put(socket, _k, nil), do: socket
      defp maybe_put(socket, k, v), do: Phoenix.Component.assign(socket, k, v)
      defp trim_or_nil(socket), do: socket

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

  # Issue #15 regression: unqualified calls to local helpers inside a
  # `run fn` body must *resolve at runtime*, not just compile cleanly.
  # The pre-fix runtime used `:erl_eval`, which has no local function
  # table; the body raised UndefinedFunctionError on `helper(...)` even
  # though the compiler saw the reference.
  defmodule LocalHelperRuntime do
    use Lavash.LiveView

    state :doubled, :integer, default: 0

    actions do
      action :compute, [:n] do
        run fn socket ->
          n =
            case socket.assigns[:n] do
              s when is_binary(s) -> String.to_integer(s)
              n when is_integer(n) -> n
            end

          Phoenix.Component.assign(socket, :doubled, double(n))
        end
      end
    end

    defp double(n), do: n * 2

    def render(assigns) do
      ~H"<div>{@doubled}</div>"
    end
  end

  test "run fn calls an unqualified local helper at runtime without UndefinedFunctionError" do
    # Drive the action runtime directly with the generated __lavash_run__/3.
    socket =
      %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}, private: %{}}
      |> Lavash.Socket.init()

    [run_entity] =
      Enum.find(LocalHelperRuntime.__lavash__(:actions), &(&1.name == :compute)).runs

    socket =
      Lavash.Action.Runtime.apply_runs(
        socket,
        :compute,
        [run_entity],
        %{n: 21},
        LocalHelperRuntime
      )

    assert Lavash.Socket.get_state(socket, :doubled) == 42
  end
end
