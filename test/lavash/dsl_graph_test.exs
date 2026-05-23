defmodule Lavash.Dsl.GraphTest do
  use ExUnit.Case, async: false

  defmodule Sample do
    use Lavash.LiveView
    state :n, :integer, default: 0
  end

  setup do
    on_exit(fn ->
      Lavash.Dsl.Graph.erase(%Macro.Env{module: Sample}, nil)
      Lavash.Reactive.erase_graph(%Macro.Env{module: Sample}, nil)
    end)

    :ok
  end

  describe "compiled_graph/1 caching" do
    test "populates :persistent_term on first call" do
      Lavash.Dsl.Graph.erase(%Macro.Env{module: Sample}, nil)
      assert :persistent_term.get({Lavash.Dsl.Graph, Sample}, :missing) == :missing

      _graph = Lavash.Dsl.Graph.compiled_graph(Sample)

      refute :persistent_term.get({Lavash.Dsl.Graph, Sample}, :missing) == :missing
    end

    test "erase/2 drops the cached graph" do
      _graph = Lavash.Dsl.Graph.compiled_graph(Sample)
      refute :persistent_term.get({Lavash.Dsl.Graph, Sample}, :missing) == :missing

      Lavash.Dsl.Graph.erase(%Macro.Env{module: Sample}, nil)

      assert :persistent_term.get({Lavash.Dsl.Graph, Sample}, :missing) == :missing
    end
  end

  describe "@after_compile invalidation" do
    test "Lavash.LiveView modules erase their cache entry on (re)compile" do
      _graph = Lavash.Dsl.Graph.compiled_graph(Sample)
      refute :persistent_term.get({Lavash.Dsl.Graph, Sample}, :missing) == :missing

      # Recompiling the module fires the @after_compile callback wired in by
      # Lavash.LiveView.Transformers.CompileLiveView. The previously-cached
      # graph would be stale, so it must be erased.
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        Code.compile_quoted(
          quote do
            defmodule unquote(Sample) do
              use Lavash.LiveView
              state :n, :integer, default: 0
              state :m, :integer, default: 1
            end
          end
        )
      end)

      assert :persistent_term.get({Lavash.Dsl.Graph, Sample}, :missing) == :missing
    end
  end
end
