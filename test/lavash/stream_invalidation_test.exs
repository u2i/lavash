defmodule Lavash.StreamInvalidationTest do
  @moduledoc """
  Server-side semantics of targeted PubSub row invalidation (issue #71
  phase 3) at the LiveViewTest level: the rendered stream reflects
  record-level {:written, id} / {:deleted, id} messages, with
  membership decided by the backing read's filters.
  """
  use Lavash.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Lavash.Test.Magic.StreamList.Entry

  defp seed!(list_id, body) do
    Entry
    |> Ash.Changeset.for_create(:create, %{list_id: list_id, body: body})
    |> Ash.create!()
  end

  test "written/deleted messages apply per-row stream ops", %{conn: conn} do
    list = "list-#{System.unique_integer([:positive])}"
    seed!(list, "row 1")

    {:ok, view, html} = live(conn, "/magic/stream-list?list_id=#{list}")
    assert html =~ "row 1"

    entry = seed!(list, "from elsewhere")
    send(view.pid, {:lavash_invalidate, Entry, {:written, entry.id}})
    assert render(view) =~ "from elsewhere"

    other = seed!("other-list", "not mine")
    send(view.pid, {:lavash_invalidate, Entry, {:written, other.id}})
    refute render(view) =~ "not mine"

    Ash.destroy!(entry)
    send(view.pid, {:lavash_invalidate, Entry, {:deleted, entry.id}})
    refute render(view) =~ "from elsewhere"
  end
end
