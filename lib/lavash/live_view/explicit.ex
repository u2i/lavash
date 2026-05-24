defmodule Lavash.LiveView.Explicit do
  @moduledoc """
  Non-DSL entry point for using the Lavash reactive graph from a plain
  Phoenix.LiveView.

  This is the path for "I want the reactive recomputation machinery
  without the Spark DSL, the `~L` template transformer, or the optimistic
  JS hook." You get the dependency graph and automatic recomputation; you
  write `mount/3`, `handle_event/3`, and `render/1` like any other
  Phoenix.LiveView.

  Compare with `use Lavash.LiveView`, which adds the DSL (`state`,
  `actions`), the template transformer (`~L`), URL/socket-backed state,
  forms, bindings, overlays, and the optimistic JS hook — a much larger
  API surface in exchange for less code at the call site.

  ## Example

      defmodule MyAppWeb.CounterLive do
        use Lavash.LiveView.Explicit

        reactive do
          state :count, 0
          state :step, 1
          derive :doubled, rx(@count * @step)
        end

        @impl Phoenix.LiveView
        def handle_event("inc", _, socket) do
          {:noreply, put_state(socket, :count, &(&1 + 1))}
        end

        @impl Phoenix.LiveView
        def render(assigns) do
          ~H\"\"\"
          <p>{@count} (doubled = {@doubled})</p>
          <button phx-click="inc">+</button>
          \"\"\"
        end
      end

  ## What `use Lavash.LiveView.Explicit` does for you

  - `use Phoenix.LiveView` and imports `Lavash.Rx.rx/1`.
  - `mount/3` is provided automatically and calls `Lavash.Reactive.init/2`
    with the graph built from `reactive do ... end`. You can override it;
    `super(params, session, socket)` does the lavash init.
  - `handle_info/2` dispatches `{:lavash_reactive, ...}` messages from
    async derives to `Lavash.Reactive.handle_async/2`. Other messages
    fall through to the user's clauses.
  - `put_state/3` is a single-call helper that combines
    `Lavash.Reactive.put/3` + `Lavash.Reactive.recompute/1` so you can't
    forget the recompute.
  - The graph is cached in `:persistent_term`. An `@after_compile` hook
    drops the cache when the module recompiles in dev.

  ## What's NOT included

  - No URL-backed or socket-backed state; you wire `handle_params/3`
    yourself.
  - No `~L` template transformer. Use `~H`. No auto-injected
    `data-lavash-*` attributes.
  - No optimistic JS hook. Updates take a server round-trip.
  - No `bind=`, no `<.lavash_component>`, no forms, no overlays. These
    are DSL features.
  """

  defmacro __using__(_opts) do
    quote do
      use Phoenix.LiveView

      import Lavash.Rx, only: [rx: 1]
      import Lavash.LiveView.Explicit, only: [reactive: 1, put_state: 3]

      Module.register_attribute(__MODULE__, :lavash_explicit_states, accumulate: true)
      Module.register_attribute(__MODULE__, :lavash_explicit_derives, accumulate: true)

      @before_compile Lavash.LiveView.Explicit
      @after_compile {Lavash.Reactive, :erase_graph}
      @after_compile {Lavash.Rx.Cache, :erase}
    end
  end

  @doc """
  Declares the reactive graph for this LiveView.

  Accepts a block of `state name, default` and `derive name, rx_expr`
  (with optional opts) calls. Translates to a `Lavash.Reactive` builder
  pipeline at compile time.

      reactive do
        state :count, 0
        derive :doubled, rx(@count * 2)
        derive :slow, rx(fetch(@count)), async: true
      end
  """
  defmacro reactive(do: block) do
    statements =
      case block do
        {:__block__, _, stmts} -> stmts
        single -> [single]
      end

    Enum.map(statements, fn
      {:state, _, [name, default]} ->
        quote do
          @lavash_explicit_states {unquote(name), unquote(default)}
        end

      {:derive, _, [name, rx]} ->
        quote do
          @lavash_explicit_derives {unquote(name), unquote(rx), []}
        end

      {:derive, _, [name, rx, opts]} ->
        quote do
          @lavash_explicit_derives {unquote(name), unquote(rx), unquote(opts)}
        end

      other ->
        raise CompileError,
          description:
            "unexpected statement inside `reactive do ... end`: #{Macro.to_string(other)}. " <>
              "Allowed: `state name, default` and `derive name, rx(...)[, opts]`."
    end)
  end

  defmacro __before_compile__(env) do
    states = Module.get_attribute(env.module, :lavash_explicit_states) |> Enum.reverse()
    derives = Module.get_attribute(env.module, :lavash_explicit_derives) |> Enum.reverse()

    quote do
      def __lavash_reactive_graph__ do
        Lavash.Reactive.graph(__MODULE__, fn ->
          builder =
            Enum.reduce(unquote(Macro.escape(states)), Lavash.Reactive.new(), fn {name, default},
                                                                                 b ->
              Lavash.Reactive.state(b, name, default)
            end)

          builder =
            Enum.reduce(unquote(Macro.escape(derives)), builder, fn {name, rx, opts}, b ->
              Lavash.Reactive.derive(b, name, rx, opts)
            end)

          Lavash.Reactive.build(builder)
        end)
      end

      @impl Phoenix.LiveView
      def mount(_params, _session, socket) do
        {:ok, Lavash.Reactive.init(socket, __lavash_reactive_graph__())}
      end

      @impl Phoenix.LiveView
      def handle_info({:lavash_reactive, _, _} = msg, socket) do
        case Lavash.Reactive.handle_async(socket, msg) do
          {:ok, socket} -> {:noreply, socket}
          :not_handled -> {:noreply, socket}
        end
      end

      defoverridable mount: 3, handle_info: 2
    end
  end

  @doc """
  Mutates a state field and immediately recomputes the dependent graph.

  Equivalent to `Lavash.Reactive.put/3 |> Lavash.Reactive.recompute/1`
  but in one call so the "forgot to recompute" footgun goes away.

      def handle_event("inc", _, socket) do
        {:noreply, put_state(socket, :count, &(&1 + 1))}
      end

  Accepts either a literal value or a 1-arity function that receives the
  current value.
  """
  def put_state(socket, field, value_or_fun) do
    socket
    |> Lavash.Reactive.put(field, value_or_fun)
    |> Lavash.Reactive.recompute()
  end
end
