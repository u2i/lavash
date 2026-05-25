defmodule DemoWeb.ToggleDemoLiveTest do
  use DemoWeb.ConnCase
  import Phoenix.LiveViewTest

  describe "toggle demo" do
    test "renders headings and the three toggles", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/demos/toggle")
      assert html =~ "Toggle Demo"
      assert html =~ "Feature Flag"
      assert html =~ "Dark Mode"
      assert html =~ "Notifications"
      assert html =~ ~s|id="feature-toggle"|
      assert html =~ ~s|id="dark-mode-toggle"|
      assert html =~ ~s|id="notifications-toggle"|
    end

    test "initial server state shows defaults", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/demos/toggle")
      # feature_enabled and dark_mode default to false, notifications to true
      assert html =~ "feature_enabled:"
      assert html =~ "dark_mode:"
      assert html =~ "notifications:"
      assert html =~ "true"
      assert html =~ "false"
    end
  end
end
