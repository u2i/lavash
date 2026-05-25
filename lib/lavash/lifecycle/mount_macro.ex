defmodule Lavash.Lifecycle.MountMacro do
  @moduledoc """
  Capability: declare what happens at LiveView mount, beyond the
  state-defaults and reactive-graph initialisation lavash sets up
  automatically.

  Symmetric with `messages do message ... end end`: the body is an
  op-sequence drawn from the shared vocabulary (`run`, `effect`,
  `set`, `fire`).

  ## Shape

      mount do
        fire :report
        fire :weather

        run fn socket ->
          Phoenix.PubSub.subscribe(MyApp.PubSub, "lobby")
          socket
        end
      end

  ## Why a block, not a callback override

  Vanilla LiveView lets you override `mount/3` and do anything. The
  block form is the declarative version of the common shapes:
  "fire these asyncs at mount", "subscribe to these topics",
  "schedule a timer", etc. The shared op vocabulary keeps the DSL
  internally consistent — the same ops work in `mount do`,
  `messages do message ...`, and (eventually) action bodies.

  ## Firing asyncs

  `fire :name` triggers an `async :name do ... end` declaration.
  Nothing about an `async` declaration is auto-fired — if a mount
  block doesn't list `fire :name`, the async never runs at mount.
  This is the central design choice of the layer-1 trigger model:
  declarations describe WHAT, lifecycle blocks describe WHEN.

  ## `when_connected do ... end`

  A guard block for ops that should only run when the LiveView is
  on a real websocket connection — the second mount that happens
  after the initial HTTP render. Same op vocabulary as the outer
  block. Compiles to an `if Phoenix.LiveView.connected?(socket)`
  wrapping the inner ops.

  Use it for PubSub subscriptions, `Process.send_after` self-timers,
  and other side effects that would be wasted (or harmful) on the
  HTTP-only first mount:

      mount do
        fire :report

        when_connected do
          run fn socket ->
            Phoenix.PubSub.subscribe(MyApp.PubSub, "lobby")
            Process.send_after(self(), :tick, 1000)
            socket
          end
        end
      end

  Note: `async :foo` field defaults are initialised on BOTH mounts
  (HTTP and websocket) — the field is `AsyncResult.loading()` on
  first render whether or not its `fire` actually executed. That
  keeps the template's case clauses matching the same shape on
  both passes.
  """

  @doc """
  Top-level `mount do <ops> end` declaration. Registers a list of
  ops to run at the end of mount, after the runtime has set up
  state, reactive graph, and assigns projection.
  """
  defmacro mount(do: body) do
    ops = extract_ops(body)
    escaped_ops = Macro.escape(ops)

    quote do
      Module.register_attribute(__MODULE__, :__lavash_mount_ops__, accumulate: false)
      Module.put_attribute(__MODULE__, :__lavash_mount_ops__, unquote(escaped_ops))
    end
  end

  defp extract_ops({:__block__, _, statements}), do: Enum.map(statements, &extract_op/1)
  defp extract_ops(single_statement), do: [extract_op(single_statement)]

  defp extract_op({:run, _meta, [fn_ast]}), do: {:run, fn_ast}
  defp extract_op({:effect, _meta, [fn_ast]}), do: {:effect, fn_ast}
  defp extract_op({:set, _meta, [field, value]}), do: {:set, field, value}
  defp extract_op({:fire, _meta, [name]}), do: {:fire, name}

  # `when_connected do <ops> end` — guard block, inner ops are
  # plain ops drawn from the same vocabulary. Nesting `when_connected`
  # inside `when_connected` is allowed but pointless; we don't try
  # to detect or flatten it.
  defp extract_op({:when_connected, _meta, [[do: body]]}) do
    {:when_connected, extract_ops(body)}
  end

  defp extract_op(other) do
    raise CompileError,
      description:
        "Unsupported op inside `mount do ... end`: #{Macro.to_string(other)}. " <>
          "Allowed ops are `run fn socket -> ... end`, " <>
          "`effect fn socket -> ... end`, `set :field, rx(...)`, " <>
          "`fire :name`, and `when_connected do <ops> end`."
  end
end
