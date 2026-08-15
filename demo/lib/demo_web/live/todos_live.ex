defmodule DemoWeb.TodosLive do
  @moduledoc """
  Todo list on stream-backed projections (lavash issues #70/#71).

  The list is a `client_state ... stream true` projection: it never
  lives in assigns or `data-lavash-state` — rows feed a LiveView
  stream, and every mutation is a predicted per-row DOM operation
  confirmed by the same event's stream op on the same node:

  - **add** (`append`): Enter in the input renders the new row
    client-side under a client-minted id; the server creates the
    record under that id and the confirming `stream_insert` morphs
    the predicted node in place.
  - **toggle** (`mutate`): the row's current data rides
    `data-lavash-row`; the prediction re-renders that row with
    `done` flipped.
  - **delete** (`remove`): the node drops immediately.

  Turn on the Lag button and watch `data-lavash-provisional` rows
  (dimmed) resolve as confirmations land.
  """
  use Lavash.LiveView

  alias Demo.Todos.Todo

  # Anonymous identity: every visitor gets their own list (EnsureUser
  # plug + live_user_ensure create an anonymous user; the Reset dev
  # button wipes their data). Ownership rides the append transform —
  # projection ops carry no actor, same pattern as cart_id.
  state :user_id, :string, from: :ephemeral

  read :todo_records, Todo, :for_user do
    argument :user_id, state(:user_id)
    async false

    client_state :todos do
      key :id
      fields [:id, :title, :done]
      stream true
    end
  end

  mount do
    run fn socket ->
      Lavash.Socket.put_state(socket, :user_id, socket.assigns.current_user.id)
    end
  end

  actions do
    action :add, [:value] do
      append :todos, :create, rx(%{title: @value, done: false, user_id: @user_id})
    end

    action :toggle, [:id] do
      mutate :todos, :toggle, rx(%{done: not @item.done})
    end

    action :delete, [:id] do
      remove :todos
    end
  end

  template do
    ~H"""
    <div class="max-w-xl mx-auto px-4 py-8 space-y-6">
      <div>
        <h1 class="text-2xl font-bold">Todos</h1>
        <p class="text-sm text-base-content/60 mt-1">
          A stream-backed projection: the list never ships to the client,
          every edit predicts a single row's DOM.
        </p>
      </div>

      <input
        type="text"
        data-lavash-action="add"
        placeholder="What needs doing? (Enter to add)"
        autocomplete="off"
        class="input input-bordered w-full"
      />

      <div id="todos" phx-update="stream" class="space-y-2">
        <div
          :for={{dom_id, row} <- @streams.todos}
          id={dom_id}
          class="flex items-center gap-3 p-3 rounded-lg bg-base-200"
        >
          <button
            type="button"
            class={"btn btn-circle btn-xs " <> if(row.done, do: "btn-success", else: "btn-outline")}
            phx-click="toggle"
            phx-value-id={row.id}
            aria-label="Toggle done"
          >
            <span :if={row.done}>✓</span>
          </button>
          <span class={"flex-1 " <> if(row.done, do: "line-through opacity-50", else: "")}>
            {row.title}
          </span>
          <button
            type="button"
            class="btn btn-ghost btn-xs text-error"
            phx-click="delete"
            phx-value-id={row.id}
            aria-label="Delete"
          >
            ✕
          </button>
        </div>
      </div>
    </div>
    """
  end
end
