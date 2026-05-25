defmodule DemoWeb.ValidationDemoLiveTest do
  use DemoWeb.ConnCase
  import Phoenix.LiveViewTest

  describe "validation demo" do
    test "renders form with username/email/password fields", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/demos/validation")
      assert html =~ "Client + Server Validation"
      assert html =~ "Username"
      assert html =~ "Email"
      assert html =~ "Password"
      assert html =~ "Create Account"
    end
  end
end
