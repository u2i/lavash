defmodule DemoWeb.BindingsDemoLiveTest do
  use DemoWeb.ConnCase
  import Phoenix.LiveViewTest

  describe "bindings demo" do
    test "renders ChipSet and initial empty state", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/demos/bindings")
      assert html =~ "Bindings Demo"
      assert html =~ ~s|id="roast-filter"|
      assert html =~ ~s|data-lavash-display="selected_count">0<|
      assert html =~ ~s|data-lavash-display="has_selection">false<|
      assert html =~ "No roasts selected"
    end

    test "url-state preselects roasts and computes the chain", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/demos/bindings?roast[]=light&roast[]=dark")

      assert html =~ ~s|data-lavash-display="selected_count">2<|
      assert html =~ ~s|data-lavash-display="has_selection">true<|
      assert html =~ "2 roasts selected"
    end

    test "single selection uses singular wording", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/demos/bindings?roast[]=light")
      assert html =~ "1 roast selected"
    end
  end
end
