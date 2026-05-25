defmodule Lavash.Parity.Lavash.HandleAsyncLive do
  @moduledoc """
  Lavash DSL expression of the handle_async parity suite —
  paired with `Lavash.Parity.Vanilla.HandleAsyncLive`.

  Coverage state vs vanilla:

    * `assign_async/3` for `:report` — covered by
      `calculate :report, rx(...), async: true`. The `async: true`
      flag wraps the rx body in lavash's own async machinery,
      which produces the same `%Phoenix.LiveView.AsyncResult{}`
      shape vanilla's `assign_async/3` produces.
    * `start_async/3` + `handle_async/3` for `:fetch_count` —
      no lavash analog yet. Uses the escape hatch: a custom
      `mount/3` calls `start_async` and a custom
      `handle_async/3` writes back via `Lavash.Socket.put_state`.
      A future `async_tasks do task :fetch_count do start ...
      on_ok ... end end` block would absorb this case
      declaratively.
  """
  use Lavash.LiveView

  state :fetch_count_result, :any, default: nil, optimistic: true

  calculate :report, rx(slow_load()), async: true

  template do
    ~H"""
    <div id="handle-async-lavash">
      <p id="report">
        <%= case @report do %>
          <% %Phoenix.LiveView.AsyncResult{loading: loading} when loading != nil -> %>
            loading...
          <% %Phoenix.LiveView.AsyncResult{ok?: true, result: r} -> %>
            {r}
          <% _ -> %>
            (no report)
        <% end %>
      </p>

      <p id="fetch-count">
        {@fetch_count_result || "(none)"}
      </p>
    </div>
    """
  end

  def slow_load do
    Process.sleep(20)
    "Report ready"
  end

  # Escape hatch: start_async at mount, handle_async writes back
  # via Lavash.Socket.put_state. The `bump_state`-style discipline
  # the messages-block fix learned applies here too.
  require Phoenix.LiveView

  @impl Phoenix.LiveView
  def mount(params, session, socket) do
    {:ok, socket} = Lavash.LiveView.Runtime.mount(__MODULE__, params, session, socket)

    socket =
      Phoenix.LiveView.start_async(socket, :fetch_count, fn ->
        Process.sleep(20)
        {:ok, 42}
      end)

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_async(:fetch_count, {:ok, {:ok, count}}, socket) do
    socket =
      socket
      |> Lavash.Socket.put_state(:fetch_count_result, count)
      |> Lavash.Reactive.recompute()
      |> Lavash.Assigns.project(__MODULE__)

    {:noreply, socket}
  end

  def handle_async(:fetch_count, {:exit, reason}, socket) do
    socket =
      socket
      |> Lavash.Socket.put_state(:fetch_count_result, {:error, inspect(reason)})
      |> Lavash.Reactive.recompute()
      |> Lavash.Assigns.project(__MODULE__)

    {:noreply, socket}
  end
end
