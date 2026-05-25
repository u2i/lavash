defmodule Lavash.Lifecycle.MessagesMacro do
  @moduledoc """
  Capability: react to a server-side message arriving at this
  LiveView. Used for PubSub broadcasts, self-scheduled timers
  (`Process.send_after/3`), monitor/DOWN messages, and the like.

  Structurally parallel to `actions do action :foo do ... end end`:
  a `messages do` block holds N `message pattern do body end`
  clauses. Each clause matches a Phoenix `handle_info/2` call.

  ## Shape

      messages do
        message :tick do
          assign(socket, :ticks, socket.assigns.ticks + 1)
        end

        message {:custom, x}, [:x] do
          assign(socket, :last_msg, x)
        end

        message :pinged do
          socket
          |> assign(:broadcasts, socket.assigns.broadcasts + 1)
          |> push_event("ack", %{})
        end
      end

  The body is plain Elixir with `socket` in scope (and any
  pattern-bound variables named in the optional second arg).
  Return the updated socket. The runtime wraps the result with
  `Reactive.recompute/1` and `Assigns.project/2`, so any state
  mutations the body performs trigger downstream `calculate :foo,
  rx(...)` recomputation.

  ## Why `socket` and not `assigns`?

  Messages frequently want the full Phoenix.LiveView API:
  `push_event`, `push_patch`, `redirect`, `start_async`,
  `assign_async`, etc. All of those operate on `socket`. Limiting
  the body to `assigns` would make the message handler weaker
  than the equivalent vanilla `def handle_info(_, socket)` for
  no benefit.

  Action `run fn` bodies still take `assigns` — actions are
  state-mutation-focused so the `assigns`-shaped contract works
  well there. Messages and actions diverge intentionally.

  ## Bind list

  The optional second arg names the variables in the pattern
  that the body should see. So `message {:custom, x}, [:x]` makes
  `x` available alongside `socket`. They're already bound by the
  pattern itself; the bind list is currently a docs hint and
  reserved for future validator checks.

  ## Layer

  Layer 1: no `rx`, no JS transpile. The body is plain Elixir.
  Reactive recompute happens after the body runs.
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
  A single `message pattern do body end` clause inside a
  `messages` block. `bind` is a list of atom names appearing in
  the pattern that should be in the body's scope alongside
  `socket`.
  """
  defmacro message(pattern, bind \\ [], do: body) do
    escaped_pattern = Macro.escape(pattern)
    escaped_body = Macro.escape(body)

    quote do
      @__lavash_messages__ {:__message__, unquote(escaped_pattern), unquote(bind),
                            unquote(escaped_body)}
    end
  end
end
