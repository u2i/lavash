defmodule Lavash.MountUrlHydrationTest do
  @moduledoc """
  `mount do ... end` bodies must see URL state — plain LiveView passes
  params to mount/3, and lavash used to discard them (URL hydration
  happened only in handle_params), so mount-time reads of URL fields
  silently got nil (the ProductLive bounce).
  """
  use Lavash.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "mount lifecycle sees a path param", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/magic/mount-url/abc-123")
    assert html =~ ~s(<div id="seen">abc-123</div>)
  end

  test "mount lifecycle sees a query param", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/magic/mount-url?thing_id=from-query")
    assert html =~ "from-query"
  end

  test "absent optional URL field is nil at mount, not an error", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/magic/mount-url")
    assert html =~ "MISSING"
  end
end
