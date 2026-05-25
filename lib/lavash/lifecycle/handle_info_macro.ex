defmodule Lavash.Lifecycle.HandleInfoMacro do
  @moduledoc """
  Capability: react to a server-side message arriving at this
  LiveView. Used for PubSub broadcasts, self-scheduled timers
  (Process.send_after/3), monitor/DOWN messages, and the like.

  This is a *capability*, not a wrapper around Phoenix's
  `handle_info/2`. The DSL describes "when a message matching
  `pattern` arrives, run `body`"; the runtime happens to dispatch
  via Phoenix's callback, but that's an implementation detail.

  Captures `handle_info do on `pattern` do `body` end ... end` at
  compile time, storing each `on` clause as a tuple
  `{pattern_ast, bind_names, body_ast}` on `@__lavash_handle_info__`.
  `CompileLiveView` reads the attribute and emits one
  `def handle_info/2` clause per `on`, wrapping the body with the
  same recompute/project discipline the action runtime uses after
  every `handle_event`.

  ## Shape

      handle_info do
        on :tick do
          assign(assigns, :ticks, assigns.ticks + 1)
        end

        on {:custom_msg, msg}, [:msg] do
          assign(assigns, :last_msg, msg)
        end
      end

  The body is plain Elixir: `assigns` is a variable bound to the
  current socket's assigns map; the body should return the
  updated map (`Phoenix.Component.assign/3` does that). The
  runtime wraps each clause with `Reactive.recompute/1` and
  `Assigns.project/2`, so any state mutations the body performs
  trigger downstream calculations and template updates.

  ## Bind list

  The optional second argument to `on` names the variables in the
  pattern that should be made available to the body's scope. So
  `on {:custom_msg, msg}, [:msg]` makes `msg` available alongside
  `assigns`. Without the bind list, the pattern can still match
  but the body has no way to reference pattern variables.

  ## Layer

  This is a layer-1 (DSL) construct: no `rx`, no JS transpile.
  The body is plain Elixir. If you want reactive recompute of a
  calculated field, declare it via `calculate :foo, rx(...)`; the
  recompute happens automatically after this handler runs.
  """

  @doc """
  Top-level `handle_info do ... end` block. The body should contain
  one or more `on/2` or `on/3` calls.
  """
  defmacro handle_info(do: block) do
    quote do
      Module.register_attribute(__MODULE__, :__lavash_handle_info__, accumulate: true)
      unquote(block)
    end
  end

  @doc """
  A single `on `pattern` do `body` end` clause inside a `handle_info`
  block. `bind` is a list of atom names appearing in the pattern that
  should be in the body's scope alongside `assigns`.
  """
  defmacro on(pattern, bind \\ [], do: body) do
    escaped_pattern = Macro.escape(pattern)
    escaped_body = Macro.escape(body)

    quote do
      @__lavash_handle_info__ {:__on__, unquote(escaped_pattern), unquote(bind),
                               unquote(escaped_body)}
    end
  end
end
