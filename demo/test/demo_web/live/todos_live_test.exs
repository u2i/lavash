defmodule DemoWeb.TodosLiveTest do
  use DemoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Demo.Todos.Todo

  defp create_todo!(title, done \\ false) do
    Todo
    |> Ash.Changeset.for_create(:create, %{title: title, done: done})
    |> Ash.create!()
  end

  test "renders seeded todos from the stream", %{conn: conn} do
    todo = create_todo!("write the demo")

    {:ok, _view, html} = live(conn, "/demos/todos")
    assert html =~ "write the demo"
    assert html =~ "todos-#{todo.id}"

    # The whole point: the streamed projection ships NO list copy.
    refute html =~ ~s("todos":)
  end

  test "add creates the record and streams the row in", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/demos/todos")

    render_click(view, "add", %{"value" => "buy beans"})

    assert render(view) =~ "buy beans"
    assert [%Todo{title: "buy beans", done: false}] = Ash.read!(Todo)
  end

  test "toggle flips done on the addressed row", %{conn: conn} do
    todo = create_todo!("flip me")

    {:ok, view, _html} = live(conn, "/demos/todos")

    render_click(view, "toggle", %{"id" => todo.id})
    assert Ash.get!(Todo, todo.id).done == true
    assert render(view) =~ "line-through"

    render_click(view, "toggle", %{"id" => todo.id})
    assert Ash.get!(Todo, todo.id).done == false
    refute render(view) =~ "line-through"
  end

  test "delete removes the record and the row", %{conn: conn} do
    todo = create_todo!("remove me")
    keeper = create_todo!("keep me")

    {:ok, view, _html} = live(conn, "/demos/todos")

    render_click(view, "delete", %{"id" => todo.id})

    html = render(view)
    refute html =~ "remove me"
    assert html =~ "keep me"
    assert {:ok, nil} = Ash.get(Todo, todo.id, error?: false)
    assert {:ok, %Todo{}} = Ash.get(Todo, keeper.id, error?: false)
  end
end
