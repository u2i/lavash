defmodule Lavash.Parity.Lavash.StreamsLive do
  @moduledoc """
  Lavash DSL expression of the streams parity suite — paired
  with `Lavash.Parity.Vanilla.StreamsLive`.

  ## The gap, concretely

  Lavash doesn't (yet) have DSL surface for
  `Phoenix.LiveView.stream/3`. Every action here drops to
  `run fn socket -> ... end` to reach for `stream_insert/4`,
  `stream_delete/3`, etc. directly. Compare:

  Vanilla LV:

      def handle_event("append", %{"body" => body}, socket) do
        id = System.unique_integer([:positive])
        {:noreply, stream_insert(socket, :items, %{id: id, body: body})}
      end

  Lavash equivalent (this file):

      action :append, [:body] do
        run fn socket ->
          id = System.unique_integer([:positive])
          Phoenix.LiveView.stream_insert(socket, :items, %{id: id, body: socket.assigns.body})
        end
      end

  Half the action body is escape-hatch code. There's no
  `stream :items, :map, default: [...]` declaration; no
  `push :items, rx(...)` op; no `stream_for` integration with
  optimistic update derives.

  What would close the gap — see `docs/STREAMING.md` primitive
  #3 — is a `stream :name` field flavor that desugars
  template-time `:for` over `@items` into `phx-update="stream"`
  and rewrites `set :items, rx(@items ++ [...])` into
  `stream_insert/4`. The reactive layer would need to know
  streams aren't full assigns (they're DOM-tracked deltas) so
  bindings + optimistic patches can opt out cleanly.

  ## Why this file exists

  Even though the lavash side leans entirely on escape hatches,
  having the parity test passing locks down the behavior so a
  future `stream :name` DSL refactor has a regression target.
  When/if that lands, the actions here collapse from `run fn`
  imperatives to declarative DSL.
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
