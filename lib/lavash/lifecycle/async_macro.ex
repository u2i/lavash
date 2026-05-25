defmodule Lavash.Lifecycle.AsyncMacro do
  @moduledoc """
  Capability: declare a triggerable async task that produces a
  value into an assigns field.

  Structurally an `async :foo do ... end` block parallels
  `messages do message :foo do ... end end`: a named block holds a
  sequence of ops, and the runtime walks them in order.

  Today the body is restricted to a single `run fn assigns -> ... end`
  op — the work to perform. The runtime wraps the result in a
  `%Phoenix.LiveView.AsyncResult{}` on the named field.

  ## Shape

      async :report do
        run fn assigns ->
          {:ok, SlowService.fetch_report(assigns.user_id)}
        end
      end

  Returning `{:ok, value}` from the run fn produces
  `AsyncResult.ok(value)`. Returning a raw value also produces
  `AsyncResult.ok(value)` — the wrapper is a convenience for
  callers that want the explicit shape. Raises / exits produce
  `AsyncResult.failed/2`.

  ## Firing

  An `async` declaration on its own DOES NOTHING. It just
  registers a named computation. To actually fire it, use the
  `fire :foo` op inside a lifecycle block (`mount do`), an action
  body, or a message body. This decouples the work definition
  from the trigger — three trigger paths (mount, action, message)
  all use the same `fire` op against the same declaration.

  ## Layer

  Layer 1: an `async` declaration is plain Elixir wrapped in
  `%AsyncResult{}` plumbing. No reactive graph involvement. For
  reactive auto-recompute on dep change, see
  `calculate :foo, rx(...), async: true` (layer 2).
  """

  @doc """
  Top-level `async :name do <ops> end` declaration. Registers a
  named, triggerable async task. The body is a sequence of ops;
  today only a single `run fn assigns -> ... end` is supported.

  The named field lands on assigns as a `%Phoenix.LiveView.AsyncResult{}`.
  Before the first fire it is `AsyncResult.loading()` with
  `loading == nil` (i.e. it's an empty default); after `fire :name`
  it transitions to `loading() |> with loading: [name]`, then
  resolves to `ok(value)` or `failed(reason)`.
  """
  defmacro async(name, do: body) do
    run_fn = extract_run_fn(body, name)
    escaped_run = Macro.escape(run_fn)

    quote do
      Module.register_attribute(__MODULE__, :__lavash_async_defs__, accumulate: true)
      @__lavash_async_defs__ {:__async__, unquote(name), unquote(escaped_run)}
    end
  end

  # Walks the async body AST and pulls out the single `run fn ...`
  # call. Raises if missing, duplicated, or surrounded by other ops.
  defp extract_run_fn({:__block__, _, statements}, name) do
    do_extract(statements, name, nil)
  end

  defp extract_run_fn(single_statement, name) do
    do_extract([single_statement], name, nil)
  end

  defp do_extract([], name, nil) do
    raise CompileError,
      description: "`async :#{name} do ... end` must contain `run fn assigns -> ... end`."
  end

  defp do_extract([], _name, run_fn), do: run_fn

  defp do_extract([{:run, _meta, [fn_ast]} | rest], name, nil) do
    do_extract(rest, name, fn_ast)
  end

  defp do_extract([{:run, _meta, [_fn_ast]} | _rest], name, _run_fn) do
    raise CompileError,
      description: "`async :#{name} do ... end` may declare only one `run fn`."
  end

  defp do_extract([other | _], name, _) do
    raise CompileError,
      description:
        "Unsupported op inside `async :#{name} do ... end`: " <>
          Macro.to_string(other) <>
          ". Today only `run fn assigns -> ... end` is supported."
  end
end
