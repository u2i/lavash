defmodule Lavash.Parity.Vanilla.HandleAsyncLive do
  @moduledoc """
  Vanilla `Phoenix.LiveView` reference for the handle_async
  parity suite. Exercises:

    * `assign_async/3` — wraps an assigns key in an
      `%AsyncResult{}`; the template pattern-matches on
      loading/ok/failed
    * `start_async/3` — fires a named task; result lands in
      `handle_async/3` and is handled with arbitrary code
    * sync completion in tests via a tiny `Process.sleep` since
      the LiveView test client doesn't block on async by default
  """
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      # assign_async path: :report is wrapped in an AsyncResult
      |> assign_async(:report, fn ->
        # Tiny sleep to simulate work; tests poll.
        Process.sleep(20)
        {:ok, %{report: "Report ready"}}
      end)
      # start_async path: :fetch_count fires; handle_async/3 receives.
      |> assign(:fetch_count_result, nil)
      |> start_async(:fetch_count, fn ->
        Process.sleep(20)
        {:ok, 42}
      end)

    {:ok, socket}
  end

  @impl true
  def handle_async(:fetch_count, {:ok, {:ok, count}}, socket) do
    {:noreply, assign(socket, :fetch_count_result, count)}
  end

  def handle_async(:fetch_count, {:exit, reason}, socket) do
    {:noreply, assign(socket, :fetch_count_result, {:error, inspect(reason)})}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="handle-async-vanilla">
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
end
