defmodule DemoWeb.FormValidationDemoLiveTest do
  use DemoWeb.ConnCase
  import Phoenix.LiveViewTest

  describe "form validation demo" do
    test "renders heading and registration fields", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/demos/form-validation")
      assert html =~ "Ash Form Validation"
      assert html =~ "Name"
      assert html =~ "Email"
      assert html =~ "Age"
      assert html =~ "Register"
    end
  end
end
