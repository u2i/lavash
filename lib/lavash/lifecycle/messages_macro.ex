defmodule Lavash.Lifecycle.MessagesMacro do
  @moduledoc """
  Capability: react to a server-side message arriving at this
  LiveView. Used for PubSub broadcasts, self-scheduled timers
  (`Process.send_after/3`), monitor/DOWN messages, and the like.

  Structurally parallel to `actions do action :foo do ... end end`:
  a `messages do` block holds N `message pattern do ... end`
  clauses. Each clause body is a sequence of ops drawn from the
  same vocabulary as actions — `run`, `effect`, `set`.

  ## Shape

      messages do
        message :tick do
          set :ticks, rx(@ticks + 1)
        end

        message {:custom_msg, msg}, [:msg] do
          run fn socket ->
            assign(socket, :last_msg, msg)
          end
        end

        message :pinged do
          run fn socket ->
            socket
            |> assign(:broadcasts, socket.assigns.broadcasts + 1)
            |> push_event("ack", %{})
          end

          effect fn socket ->
            require Logger
            Logger.info("pinged: \#{socket.assigns.broadcasts}")
          end
        end
      end

  ## `run fn socket -> ... end` vs action's `run fn assigns -> ... end`

  Messages frequently want the full Phoenix.LiveView API:
  `push_event`, `push_patch`, `redirect`, `start_async`,
  `assign_async`, etc. All operate on `socket`. So `run` inside a
  `message` body takes the socket and should return the socket.

  Action `run fn` bodies take `assigns` because actions are
  state-mutation-focused — the assigns-shaped contract works well
  there. Messages and actions diverge intentionally on this point.

  ## `set :field, rx(...)`

  Same shape and semantics as inside an `action`. The reactive
  expression evaluates against the current state at fire time.
  Useful for the common "this message just bumps state" case
  without writing a full `run fn`.

  ## Bind list

  The optional second arg to `message` names the variables in the
  pattern that the body should see. So `message {:custom, x}, [:x]`
  makes `x` available in the body's `run fn` body. They're already
  bound by the pattern itself; the bind list is currently a docs
  hint and reserved for future validator checks.

  ## Layer

  Layer 1: the body is a sequence of declarative ops. `set ..., rx(...)`
  participates in layer 2 (reactive graph); `run`/`effect` are plain
  Elixir. Reactive recompute runs after the body so downstream
  `calculate :foo, rx(...)` updates correctly.
  """

  @doc """
  Top-level `messages do ... end` block. The body should contain
  one or more `message/2` or `message/3` calls.
  """
  defmacro messages(do: block) do
    quote do
      Module.register_attribute(__MODULE__, :__lavash_messages__, accumulate: true)
      unquote(block)
    end
  end

  @doc """
  A single `message pattern do <ops> end` clause inside a
  `messages` block. `bind` is a list of atom names appearing in
  the pattern that should be in the body's scope alongside the
  socket.

  The body is a sequence of op calls (`run`/`effect`/`set`). Each
  is captured at compile time and stored on the clause; the
  runtime executes them in order, passing the socket through.
  """
  defmacro message(pattern, bind \\ [], do: body) do
    ops = extract_ops(body)
    escaped_pattern = Macro.escape(pattern)
    escaped_ops = Macro.escape(ops)

    quote do
      @__lavash_messages__ {:__message__, unquote(escaped_pattern), unquote(bind),
                            unquote(escaped_ops)}
    end
  end

  # Walks a message body AST and extracts a sequence of op tuples.
  # The body is either a single op call or a `__block__` of multiple
  # op calls. Each op call is one of:
  #
  #   * `{:run, _, [fn_ast]}`     — captured as `{:run, fn_ast}`
  #   * `{:effect, _, [fn_ast]}`  — captured as `{:effect, fn_ast}`
  #   * `{:set, _, [field, rx_or_value]}` — captured as `{:set, field, value}`
  #
  # Anything else inside the body is a syntax error.
  defp extract_ops({:__block__, _, statements}) do
    Enum.map(statements, &extract_op/1)
  end

  defp extract_ops(single_statement) do
    [extract_op(single_statement)]
  end

  defp extract_op({:run, _meta, [fn_ast]}), do: {:run, fn_ast}
  defp extract_op({:effect, _meta, [fn_ast]}), do: {:effect, fn_ast}
  defp extract_op({:set, _meta, [field, value]}), do: {:set, field, value}

  defp extract_op(other) do
    raise CompileError,
      description:
        "Unsupported op inside `message do ... end`: #{Macro.to_string(other)}. " <>
          "Allowed ops are `run fn socket -> ... end`, " <>
          "`effect fn socket -> ... end`, and `set :field, rx(...)`."
  end
end
