defmodule Lavash.Parity.Lavash.StreamsLive do
  @moduledoc """
  Lavash DSL expression of the streams parity suite — paired
  with `Lavash.Parity.Vanilla.StreamsLive`.

  ## Using socket-shape `run`

  Earlier versions of this fixture were tagged `:parity_gap`
  because `run` was assigns-shaped and dropped socket-level
  changes. Since #117 collapsed the assigns-shape into the
  socket-shape, `run` is post-cascade and accepts a socket
  wholesale — the gap closes.

  Compare:

      action :append, [:body] do
        run fn socket ->
          id = System.unique_integer([:positive])
          Phoenix.LiveView.stream_insert(
            socket,
            :items,
            %{id: id, body: socket.assigns.body}
          )
        end
      end

  vs. the previous attempt with plain `run` (which silently
  dropped the stream changes because the action runtime extracted
  `__changed__` from assigns and the assign map wasn't the source
  of truth for streams).

  ## Still missing — a declarative `stream :name` flavor

  This fixture works today but it's verbose. A future
  `stream :name` declaration plus `push :items, value` /
  `delete :items, value` ops would let this collapse to:

      stream :items, :map, default: [%{id: 1, body: "first"}, ...]

      actions do
        action :append, [:body] do
          push :items, rx(%{id: next_id(), body: @body})
        end
      end

  See `docs/STREAMING.md` primitive #3 for the design sketch.
  """
  use Lavash.LiveView

  mount do
    run fn socket ->
      initial = [
        %{id: 1, body: "first"},
        %{id: 2, body: "second"}
      ]

      Phoenix.LiveView.stream(socket, :items, initial)
    end
  end

  actions do
    action :append, [:body] do
      run fn socket ->
        id = System.unique_integer([:positive])

        Phoenix.LiveView.stream_insert(
          socket,
          :items,
          %{id: id, body: socket.assigns.body}
        )
      end
    end

    action :prepend, [:body] do
      run fn socket ->
        id = System.unique_integer([:positive])

        Phoenix.LiveView.stream_insert(
          socket,
          :items,
          %{id: id, body: socket.assigns.body},
          at: 0
        )
      end
    end

    action :delete, [:id] do
      run fn socket ->
        id = String.to_integer(socket.assigns.id)
        Phoenix.LiveView.stream_delete(socket, :items, %{id: id, body: ""})
      end
    end

    action :reset do
      run fn socket ->
        new_items = [%{id: 999, body: "reset"}]
        Phoenix.LiveView.stream(socket, :items, new_items, reset: true)
      end
    end
  end

  template do
    ~H"""
    <div id="streams-lavash">
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
