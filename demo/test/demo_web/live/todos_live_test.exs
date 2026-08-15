defmodule DemoWeb.TodosLiveTest do
  use DemoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  require Ash.Query

  alias Demo.Todos.Todo

  # EnsureUser creates the visitor's anonymous user on the first
  # request; run one so seeded rows can belong to the same user the
  # LiveView will see.
  defp with_user(conn) do
    conn = get(conn, "/")
    {conn, conn.assigns.current_user}
  end

  defp create_todo!(user, title, done \\ false) do
    Todo
    |> Ash.Changeset.for_create(:create, %{title: title, done: done, user_id: user.id})
    |> Ash.create!()
  end

  defp user_todos(user) do
    Todo |> Ash.Query.filter(user_id == ^user.id) |> Ash.read!()
  end

  test "renders only the visitor's own todos", %{conn: conn} do
    {conn, user} = with_user(conn)
    todo = create_todo!(user, "write the demo")

    other =
      Demo.Accounts.User |> Ash.Changeset.for_create(:create_anonymous) |> Ash.create!()

    create_todo!(other, "someone else's secret")

    {:ok, _view, html} = live(conn, "/demos/todos")
    assert html =~ "write the demo"
    assert html =~ "todos-#{todo.id}"
    refute html =~ "someone else's secret"

    # The whole point: the streamed projection ships NO list copy.
    refute html =~ ~s("todos":)
  end

  test "add creates the record under the visitor's user", %{conn: conn} do
    {conn, user} = with_user(conn)
    {:ok, view, _html} = live(conn, "/demos/todos")

    render_click(view, "add", %{"value" => "buy beans"})

    assert render(view) =~ "buy beans"
    assert [%Todo{title: "buy beans", done: false, user_id: user_id}] = user_todos(user)
    assert user_id == user.id
  end

  test "toggle flips done on the addressed row", %{conn: conn} do
    {conn, user} = with_user(conn)
    todo = create_todo!(user, "flip me")

    {:ok, view, _html} = live(conn, "/demos/todos")

    render_click(view, "toggle", %{"id" => todo.id})
    assert Ash.get!(Todo, todo.id).done == true
    assert render(view) =~ "line-through"

    render_click(view, "toggle", %{"id" => todo.id})
    assert Ash.get!(Todo, todo.id).done == false
    refute render(view) =~ "line-through"
  end

  test "delete removes the record and the row", %{conn: conn} do
    {conn, user} = with_user(conn)
    todo = create_todo!(user, "remove me")
    keeper = create_todo!(user, "keep me")

    {:ok, view, _html} = live(conn, "/demos/todos")

    render_click(view, "delete", %{"id" => todo.id})

    html = render(view)
    refute html =~ "remove me"
    assert html =~ "keep me"
    assert {:ok, nil} = Ash.get(Todo, todo.id, error?: false)
    assert {:ok, %Todo{}} = Ash.get(Todo, keeper.id, error?: false)
  end

  test "reset wipes the visitor's data and only theirs", %{conn: conn} do
    {conn, user} = with_user(conn)
    create_todo!(user, "mine")

    other =
      Demo.Accounts.User |> Ash.Changeset.for_create(:create_anonymous) |> Ash.create!()

    create_todo!(other, "not mine")

    conn = post(conn, "/dev/reset")
    assert redirected_to(conn) == "/"

    # Reset destroys the visitor themselves — cascades take their data.
    assert {:ok, nil} = Ash.get(Demo.Accounts.User, user.id, error?: false)
    assert user_todos(user) == []
    assert [%Todo{title: "not mine"}] = user_todos(other)

    # The next request mints a fresh identity.
    conn = get(conn, "/")
    assert conn.assigns.current_user.id != user.id
  end
end
