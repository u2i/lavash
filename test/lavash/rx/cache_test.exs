defmodule Lavash.Rx.CacheTest do
  use ExUnit.Case, async: false

  alias Lavash.Rx.Cache

  defmodule Sample do
    def __noop__, do: :ok
  end

  setup do
    Cache.erase(%Macro.Env{module: Sample}, nil)
    on_exit(fn -> Cache.erase(%Macro.Env{module: Sample}, nil) end)
    :ok
  end

  # Build an AST whose `state` reference matches what the rx macro produces
  # (context: nil), via Macro.var/2.
  defp state_var, do: Macro.var(:state, nil)

  describe "compile_rx/2" do
    test "produces a callable function from a state-referring AST" do
      ast = quote do: Map.get(unquote(state_var()), :count) * 2
      fun = Cache.compile_rx(Sample, ast)
      assert fun.(%{count: 21}) == 42
    end

    test "returns the same function instance on subsequent calls (cache hit)" do
      ast = quote do: Map.get(unquote(state_var()), :count) + 1
      fun1 = Cache.compile_rx(Sample, ast)
      fun2 = Cache.compile_rx(Sample, ast)
      assert :erlang.fun_info(fun1, :uniq) == :erlang.fun_info(fun2, :uniq)
    end

    test "erase/2 drops the cache so the next call repopulates" do
      ast = quote do: Map.get(unquote(state_var()), :n)
      key = {Cache, Sample, :rx, :erlang.phash2(ast)}

      _ = Cache.compile_rx(Sample, ast)
      refute :persistent_term.get(key, :missing) == :missing

      Cache.erase(%Macro.Env{module: Sample}, nil)
      assert :persistent_term.get(key, :missing) == :missing

      _ = Cache.compile_rx(Sample, ast)
      refute :persistent_term.get(key, :missing) == :missing
    end
  end
end
