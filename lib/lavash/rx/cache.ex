defmodule Lavash.Rx.Cache do
  @moduledoc """
  Module-scoped node-global cache for compiled `rx()` ASTs.

  User-supplied ASTs (the `:ast` field of `%Lavash.Rx{}`, action `run`
  function ASTs, etc.) are stored in the Spark DSL state in quoted form.
  Re-evaluating them via `Code.eval_quoted/3` on every fire is the slow
  path: it re-parses, re-expands, and re-evaluates each call.

  This module caches the compiled function in `:persistent_term` keyed by
  `{Lavash.Rx.Cache, module, kind, identifier}` so the eval cost is paid
  once per module load instead of once per fire.

  The Lavash compile transformers wire `erase/2` into `@after_compile` so a
  hot recompile in dev drops all cached entries for the affected module.
  """

  @doc """
  Returns a cached function compiled from the given AST.

  On the first call for a key, runs `compile.()` to produce the function and
  stashes it. Subsequent calls return the cached function directly.

  `compile` is a thunk to defer the work until the cache misses; callers
  should not pay eval cost on the hit path.
  """
  @spec get_or_compile(term(), (-> (term() -> term()))) :: (term() -> term())
  def get_or_compile(key, compile) when is_function(compile, 0) do
    case :persistent_term.get(key, :__rx_cache_miss__) do
      :__rx_cache_miss__ ->
        fun = compile.()
        :persistent_term.put(key, fun)
        fun

      fun ->
        fun
    end
  end

  @doc """
  Compile a `%Lavash.Rx{}` AST into `fn state -> ... end` and cache it under
  `{Lavash.Rx.Cache, module, :rx, ast_hash}`.
  """
  @spec compile_rx(module(), Macro.t()) :: (map() -> term())
  def compile_rx(module, ast) do
    key = {__MODULE__, module, :rx, :erlang.phash2(ast)}

    get_or_compile(key, fn ->
      fn_ast = {:fn, [], [{:->, [], [[{:state, [], nil}], ast]}]}
      {fun, _} = Code.eval_quoted(fn_ast, [], %{__ENV__ | module: module})
      fun
    end)
  end

  @doc """
  Compile an action `run` lambda AST (with `Phoenix.Component.assign/3`
  imported) into a callable function. Cached under
  `{Lavash.Rx.Cache, module, :run_fun, ast_hash}`.
  """
  @spec compile_run_fun(module(), Macro.t()) :: (map() -> map())
  def compile_run_fun(module, fun_ast) do
    key = {__MODULE__, module, :run_fun, :erlang.phash2(fun_ast)}

    get_or_compile(key, fn ->
      wrapped =
        quote do
          import Phoenix.Component, only: [assign: 3]
          unquote(fun_ast)
        end

      {fun, _} = Code.eval_quoted(wrapped, [], %{__ENV__ | module: module})
      fun
    end)
  end

  @doc """
  Drops all cached entries for `module`. Wired into Lavash modules'
  `@after_compile` so dev recompiles rebuild the cache from the new AST
  instead of returning stale fns.

  Matches the `@after_compile` callback signature `(env, bytecode)`.
  """
  @spec erase(Macro.Env.t(), binary() | nil) :: :ok
  def erase(%Macro.Env{module: module}, _bytecode) do
    # Walk all persistent_term entries and drop any keyed on this module.
    # The store is small (one entry per rx/run-fun per Lavash module) so the
    # full scan is acceptable here.
    Enum.each(:persistent_term.get(), fn
      {{__MODULE__, ^module, _kind, _id} = key, _value} ->
        :persistent_term.erase(key)

      _ ->
        :ok
    end)

    :ok
  end
end
