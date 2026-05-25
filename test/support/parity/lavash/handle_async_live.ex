defmodule Lavash.Parity.Lavash.HandleAsyncLive do
  @moduledoc """
  Lavash DSL expression of the handle_async parity suite —
  paired with `Lavash.Parity.Vanilla.HandleAsyncLive`.

  Both async paths are now lavash-native:

    * `assign_async/3` for `:report` — covered by
      `calculate :report, rx(...), async: true`. The reactive
      layer wraps the rx body in lavash's async machinery, which
      produces the same `%Phoenix.LiveView.AsyncResult{}` shape
      vanilla's `assign_async/3` produces.

    * `start_async/3` + `handle_async/3` for `:fetch_count` —
      covered by `async :fetch_count do run fn ... end end` +
      `mount do fire :fetch_count end`. The `async` declaration
      registers a triggerable task; the `mount` block fires it at
      mount. The result lands on `@fetch_count` as an
      `%AsyncResult{}` — symmetric with `:report`.
  """
  use Lavash.LiveView

  calculate :report, rx(slow_load()), async: true

  async :fetch_count do
    run fn _assigns ->
      Process.sleep(20)
      {:ok, 42}
    end
  end

  mount do
    fire :fetch_count
  end

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
        <%= case @fetch_count do %>
          <% %Phoenix.LiveView.AsyncResult{ok?: true, result: r} -> %>
            {r}
          <% _ -> %>
            (none)
        <% end %>
      </p>
    </div>
    """
  end

  def slow_load do
    Process.sleep(20)
    "Report ready"
  end
end
