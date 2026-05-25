defmodule DemoWeb.Storefront.CheckoutLiveTest do
  use DemoWeb.ConnCase
  import Phoenix.LiveViewTest

  describe "storefront checkout" do
    test "mounts (empty cart redirects or renders empty state)", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/storefront/checkout")
      # Empty cart: page mounts; we just sanity-check the lavash root is present
      assert html =~ "lavash-optimistic-root"
    end
  end
end
