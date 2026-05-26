defmodule Lavash.Parity.Vanilla.StreamsLive do
  @moduledoc """
  Vanilla `Phoenix.LiveView` reference for the streams parity
  suite.

  Exercises the four core `Phoenix.LiveView.stream` ops:

    * `stream/3` — declare and seed
    * `stream_insert/4` — append/prepend/insert-at items
    * `stream_delete/3` — remove an item
    * `stream/4` with `reset: true` — replace the collection

  Each stream item is a `%{id: integer, body: string}` so the test
  can address rows by id and assert on rendered text.

  ## Why a parity test for streams?

  Streams are a load-bearing LV primitive for append-only or
  scrolling collections (chat messages, log tails, search
  results) because they avoid resending the whole list on every
  update. Lavash doesn't expose `stream/3` as DSL surface today
  (see `docs/STREAMING.md`); this fixture is the vanilla half of
  a parity pair, and the lavash side uses `run fn socket -> ... end`
  to reach for raw `Phoenix.LiveView.stream/3` — establishing
  the gap concretely.
  """
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    initial = [
      %{id: 1, body: "first"},
      %{id: 2, body: "second"}
    ]

    {:ok, stream(socket, :items, initial)}
  end

  @impl true
  def handle_event("append", %{"body" => body}, socket) do
    id = System.unique_integer([:positive])
    {:noreply, stream_insert(socket, :items, %{id: id, body: body})}
  end

  @impl true
  def handle_event("prepend", %{"body" => body}, socket) do
    id = System.unique_integer([:positive])
    {:noreply, stream_insert(socket, :items, %{id: id, body: body}, at: 0)}
  end

  @impl true
  def handle_event("delete", %{"id" => id_str}, socket) do
    id = String.to_integer(id_str)
    {:noreply, stream_delete(socket, :items, %{id: id, body: ""})}
  end

  @impl true
  def handle_event("reset", _params, socket) do
    new_items = [%{id: 999, body: "reset"}]
    {:noreply, stream(socket, :items, new_items, reset: true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="streams-vanilla">
      <ul id="items" phx-update="stream">
        <li :for={{dom_id, item} <- @streams.items} id={dom_id}>
          <span class="body">{item.body}</span>
          <button
            class="delete"
            phx-click="delete"
            phx-value-id={item.id}
          >×</button>
        </li>
      </ul>

      <form phx-submit="append">
        <input name="body" />
        <button type="submit" id="append">append</button>
      </form>

      <form phx-submit="prepend">
        <input name="body" />
        <button type="submit" id="prepend">prepend</button>
      </form>

      <button id="reset" phx-click="reset">reset</button>
    </div>
    """
  end
end
