defmodule DemoWeb.LiveViewDemos.TodosLive do
  @moduledoc """
  Todos in pure Elixir — the zero-macro floor of the lavash design.

  No DSL, no `rx()`, no `defgraph`, no `reactive` block. Everything
  the macros normally derive is written out by hand:

  - the graph is built with `Reactive.new/state/derive/build`, where
    every derive names its dependencies explicitly and computes with
    a plain function taking a map of dep values
  - writes are ordinary Ash calls; each one broadcasts a fine-grained
    invalidation (`Lavash.PubSub.broadcast_mutation` on the user_id
    topic) and re-fetches locally via `Reactive.invalidate/2`
  - mount subscribes to exactly this user's topic
    (`subscribe_combination`), so another tab editing the same list
    updates this one, but other users' writes don't even arrive

  Compare with `/demos/todos`: same feature set, where the DSL adds
  stream projections and per-row optimistic predictions on top of
  this exact machinery.
  """
  use DemoWeb, :live_view

  alias Demo.Todos.Todo
  alias Lavash.Reactive

  # The whole reactive layer, spelled out. Dependencies are explicit
  # lists; compute functions receive a map of the named dep values.
  defp graph do
    Reactive.graph(__MODULE__, fn ->
      Reactive.new()
      |> Reactive.state(:user_id, nil)
      |> Reactive.state(:filter, "all")
      |> Reactive.derive(:todos, [:user_id], &fetch_todos/1)
      |> Reactive.derive(:visible_todos, [:todos, :filter], &apply_filter/1)
      |> Reactive.derive(:remaining, [:todos], fn %{todos: todos} ->
        Enum.count(todos, &(!&1.done))
      end)
      |> Reactive.derive(:done_count, [:todos], fn %{todos: todos} ->
        Enum.count(todos, & &1.done)
      end)
      |> Reactive.build()
    end)
  end

  def fetch_todos(%{user_id: nil}), do: []

  def fetch_todos(%{user_id: user_id}) do
    Todo
    |> Ash.Query.for_read(:for_user, %{user_id: user_id})
    |> Ash.read!()
  end

  def apply_filter(%{todos: todos, filter: "active"}), do: Enum.reject(todos, & &1.done)
  def apply_filter(%{todos: todos, filter: "done"}), do: Enum.filter(todos, & &1.done)
  def apply_filter(%{todos: todos, filter: _}), do: todos

  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]
    user_id = user && user.id

    # Only THIS user's todo mutations arrive here — the topic carries
    # the user_id, so other visitors' writes are never even delivered.
    if connected?(socket) && user_id do
      Lavash.PubSub.subscribe_combination(Todo, [:user_id], %{user_id: user_id})
    end

    socket =
      socket
      |> Reactive.init(graph())
      |> Reactive.put(:user_id, user_id)
      |> Reactive.recompute()
      |> assign(:draft, "")

    {:ok, socket}
  end

  # ── Writes: ordinary Ash calls + broadcast + local re-fetch ──────

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
    todo = Enum.find(socket.assigns.todos, &(&1.id == id))

    if todo do
      todo
      |> Ash.Changeset.for_update(:toggle, %{done: !todo.done})
      |> Ash.update!()
    end

    {:noreply, after_write(socket)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.todos, &(&1.id == id)) do
      nil -> :ok
      todo -> Ash.destroy!(todo)
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
    {:noreply, socket |> Reactive.put(:filter, filter) |> Reactive.recompute()}
  end

  # Raw Ash writes don't broadcast anything — that's a lavash form/
  # projection concern. Here the loop is manual: tell every subscriber
  # on this user's topic (other tabs), then re-fetch locally without
  # waiting for our own copy of the broadcast to arrive.
  defp after_write(socket) do
    user_id = socket.assigns.user_id

    Lavash.PubSub.broadcast_mutation(Todo, [:user_id], %{}, %{user_id: user_id})

    Reactive.invalidate(socket, :todos)
  end

  # Another tab (same user) wrote — re-run the :todos derive. Our own
  # writes also echo here; the extra read is the cost of keeping the
  # handler dumb.
  def handle_info({:lavash_invalidate, Todo}, socket) do
    {:noreply, Reactive.invalidate(socket, :todos)}
  end

  def handle_info(msg, socket) do
    case Reactive.handle_async(socket, msg) do
      {:ok, socket} -> {:noreply, socket}
      :not_handled -> {:noreply, socket}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-md mx-auto mt-10 p-6 card bg-base-200">
      <h1 class="text-2xl font-bold text-center mb-2">Todos (Pure Elixir)</h1>
      <p class="text-sm text-base-content/60 text-center mb-6">
        Zero macros — explicit deps, plain functions, hand-wired PubSub
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

      <div class="mt-6 p-4 bg-base-100 rounded-lg text-sm text-base-content/70 space-y-1">
        <h3 class="font-semibold text-base-content">What the DSL would add</h3>
        <p>
          <a href="/demos/todos" class="link">/demos/todos</a>
          is this same page with stream projections (rows never ship as state) and
          per-row optimistic predictions (add/toggle/delete render before the round-trip).
          The graph underneath is the one you're reading here.
        </p>
      </div>

      <div class="mt-6 text-center">
        <a href="/lv" class="link text-sm">&larr; LiveView demos</a>
      </div>
    </div>
    """
  end
end
