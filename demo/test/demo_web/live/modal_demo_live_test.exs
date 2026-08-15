defmodule DemoWeb.ModalDemoLiveTest do
  use DemoWeb.ConnCase
  import Phoenix.LiveViewTest

  describe "modal demo" do
    test "renders the demo page with an Open Modal button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dsl/modal")
      assert html =~ "Modal Demo"
      assert html =~ "Open Modal"
      assert html =~ "simple-modal"
    end

    test "clicking Open Modal flips modal_open to true", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dsl/modal")

      html = view |> element("button", "Open Modal") |> render_click()
      # State has been bumped; modal_open is now true on the root
      assert html =~ "modal_open"
      assert html =~ "true"
    end
  end
end
