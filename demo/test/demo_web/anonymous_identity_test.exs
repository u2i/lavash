defmodule DemoWeb.AnonymousIdentityTest do
  @moduledoc """
  The anonymous-identity contract: one persistent user per visitor,
  shared across every db-backed surface, no login required.
  """
  use DemoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "the same anonymous user follows the visitor across all scopes", %{conn: conn} do
    conn = get(conn, "/")
    user = conn.assigns.current_user
    assert user.anonymous

    for path <- ["/demos/todos", "/storefront", "/account/orders"] do
      conn = get(conn, path)

      assert conn.assigns.current_user.id == user.id,
             "expected the same anonymous user on #{path}"
    end
  end

  test "the identity cookie is persistent, not browser-session-scoped", %{conn: conn} do
    conn = get(conn, "/")

    [cookie] = get_resp_header(conn, "set-cookie") |> Enum.filter(&(&1 =~ "_demo_key"))
    assert cookie =~ ~r/max-age=\d+/i
  end

  test "anonymous visitors reach their account pages without signing in", %{conn: conn} do
    conn = get(conn, "/")

    {:ok, _view, html} = live(conn, "/account/orders")
    assert html =~ "Orders" or html =~ "orders"
  end
end
