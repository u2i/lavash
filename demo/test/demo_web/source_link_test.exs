defmodule DemoWeb.SourceLinkTest do
  use DemoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "github_url resolves a demo module to its main-branch blob URL" do
    assert DemoWeb.SourceLink.github_url(DemoWeb.TodosLive) ==
             "https://github.com/u2i/lavash/blob/main/demo/lib/demo_web/live/todos_live.ex"
  end

  test "every demo page renders its view-source pill", %{conn: conn} do
    for path <- ["/demos/todos", "/demos/toggle", "/storefront", "/account/orders", "/"] do
      {:ok, _view, html} = live(conn, path)

      assert html =~ "https://github.com/u2i/lavash/blob/main/demo/lib/demo_web/live/",
             "expected a source link on #{path}"
    end
  end
end
