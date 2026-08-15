defmodule DemoWeb.Reactive.TodosLive do
  @moduledoc """
  Todos on the reactive DSL — `use Lavash.LiveView.Explicit` with a
  `reactive do` block and `rx()` derives.

  The middle rung of the todos row: `/builder/todos` writes this
  graph out with the core API (explicit deps, plain functions), and
  `/dsl/todos` adds stream projections and per-row optimistic
  predictions on top. Writes, PubSub, and re-fetching are identical
  to the builder version — the DSL only compresses the graph
  declaration.
  """
  use Lavash.LiveView.Explicit

  alias Demo.Todos.Todo

  reactive do
    state :user_id, nil
    state :filter, "all"
    derive :todos, rx(fetch_todos(@user_id))
    derive :visible_todos, rx(apply_filter(@todos, @filter))
    derive :remaining, rx(Enum.count(@todos, &(!&1.done)))
    derive :done_count, rx(Enum.count(@todos, & &1.done))
  end

  # Public: rx() compute functions are compiled outside the module's
  # private scope.
  def fetch_todos(nil), do: []

  def fetch_todos(user_id) do
    Todo
    |> Ash.Query.for_read(:for_user, %{user_id: user_id})
    |> Ash.read!()
  end

  def apply_filter(todos, "active"), do: Enum.reject(todos, & &1.done)
  def apply_filter(todos, "done"), do: Enum.filter(todos, & &1.done)
  def apply_filter(todos, _), do: todos

  @impl Phoenix.LiveView
  def mount(params, session, socket) do
    {:ok, socket} = super(params, session, socket)

    user = socket.assigns[:current_user]
    user_id = user && user.id

    if connected?(socket) && user_id do
      Lavash.PubSub.subscribe_combination(Todo, [:user_id], %{user_id: user_id})
    end

    {:ok, socket |> put_state(:user_id, user_id) |> assign(:draft, "")}
  end

  @impl Phoenix.LiveView
  def handle_event("add", %{"title" => title}, socket) do
    title = String.trim(title)

    if title == "" do
      {:noreply, socket}
    else
      Todo
      |> Ash.Changeset.for_create(:create, %{title: title, user_id: socket.assigns.user_id})
      |> Ash.create!()

      {:noreply, socket |> assign(:draft, "") |> after_write()}
    end
  end

  def handle_event("draft", %{"title" => title}, socket) do
    {:noreply, assign(socket, :draft, title)}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    with %Todo{} = todo <- Enum.find(socket.assigns.todos, &(&1.id == id)) do
      todo
      |> Ash.Changeset.for_update(:toggle, %{done: !todo.done})
      |> Ash.update!()
    end

    {:noreply, after_write(socket)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with %Todo{} = todo <- Enum.find(socket.assigns.todos, &(&1.id == id)) do
      Ash.destroy!(todo)
    end

    {:noreply, after_write(socket)}
  end

  def handle_event("clear_done", _, socket) do
    socket.assigns.todos
    |> Enum.filter(& &1.done)
    |> Enum.each(&Ash.destroy!/1)

    {:noreply, after_write(socket)}
  end

  def handle_event("set_filter", %{"filter" => filter}, socket) do
    {:noreply, put_state(socket, :filter, filter)}
  end

  defp after_write(socket) do
    user_id = socket.assigns.user_id
    Lavash.PubSub.broadcast_mutation(Todo, [:user_id], %{}, %{user_id: user_id})
    Lavash.Reactive.invalidate(socket, :todos)
  end

  @impl Phoenix.LiveView
  def handle_info({:lavash_invalidate, Todo}, socket) do
    {:noreply, Lavash.Reactive.invalidate(socket, :todos)}
  end

  def handle_info(msg, socket) do
    case Lavash.Reactive.handle_async(socket, msg) do
      {:ok, socket} -> {:noreply, socket}
      :not_handled -> {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="max-w-md mx-auto mt-10 p-6 card bg-base-200">
      <h1 class="text-2xl font-bold text-center mb-2">Todos (Reactive DSL)</h1>
      <p class="text-sm text-base-content/60 text-center mb-6">
        <code class="bg-base-300 px-1 rounded">reactive do</code>
        block + <code class="bg-base-300 px-1 rounded">rx()</code>
        derives — no optimistic layer
      </p>

      <form id="todo-form" phx-submit="add" phx-change="draft" class="flex gap-2 mb-4">
        <input
          type="text"
          name="title"
          value={@draft}
          placeholder="What needs doing?"
          autocomplete="off"
          class="input input-bordered flex-1"
        />
        <button type="submit" class="btn btn-primary">Add</button>
      </form>

      <div class="flex justify-center gap-1 mb-4">
        <button
          :for={f <- ~w(all active done)}
          phx-click="set_filter"
          phx-value-filter={f}
          class={["btn btn-xs", if(@filter == f, do: "btn-primary", else: "btn-ghost")]}
        >
          {f}
        </button>
      </div>

      <ul class="space-y-2 mb-4">
        <li
          :for={todo <- @visible_todos}
          class="flex items-center gap-3 p-3 rounded-lg bg-base-100"
        >
          <input
            type="checkbox"
            checked={todo.done}
            phx-click="toggle"
            phx-value-id={todo.id}
            class="checkbox checkbox-primary checkbox-sm"
          />
          <span class={["flex-1", todo.done && "line-through text-base-content/40"]}>
            {todo.title}
          </span>
          <button
            phx-click="delete"
            phx-value-id={todo.id}
            class="btn btn-ghost btn-xs text-error"
            aria-label="Delete"
          >
            &#10005;
          </button>
        </li>
        <li :if={@visible_todos == []} class="text-center text-base-content/40 py-6">
          Nothing here.
        </li>
      </ul>

      <div class="flex items-center justify-between text-sm text-base-content/60">
        <span>{@remaining} remaining</span>
        <button :if={@done_count > 0} phx-click="clear_done" class="btn btn-ghost btn-xs">
          Clear {@done_count} done
        </button>
      </div>

      <div class="mt-6 text-center">
        <a href="/" class="link text-sm">&larr; All demos</a>
      </div>
    </div>
    """
  end
end
