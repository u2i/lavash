defmodule DemoWeb.TagEditorDemoLiveTest do
  use DemoWeb.ConnCase
  import Phoenix.LiveViewTest

  describe "tag editor demo" do
    test "renders heading and default tags from URL", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/demos/tag-editor")
      assert html =~ "Tag Editor Demo"
      assert html =~ "Tag Editor A"
      assert html =~ "Tag Editor B (Sibling)"
      # Default tags are elixir, phoenix; tags_display joins with ", "
      assert html =~ "elixir"
      assert html =~ "phoenix"
    end

    test "tag_summary reflects the URL-state tags", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/demos/tag-editor?tags[]=ruby&tags[]=rails&tags[]=hanami")
      # 3 tags
      assert html =~ "3 tags"
    end
  end
end
