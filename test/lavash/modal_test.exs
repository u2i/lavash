defmodule Lavash.ModalTest do
  use Lavash.ConnCase, async: false

  describe "close_on_escape / close_on_backdrop configuration" do
    # Regression for issue #24: RenderGenerator read the persisted option
    # with `|| true`, so a configured `false` became `false || true` and
    # both options were impossible to turn off.

    test "close_on_escape false is exposed to the client escape handler", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/magic/modal-no-close-host")

      # Escape is handled client-side by the overlay a11y stack, which
      # reads data-close-on-escape from the chrome root.
      chrome = view |> element("#test-modal-no-close-modal") |> render()
      assert chrome =~ ~s(data-close-on-escape="false")
    end

    test "close_on_backdrop false renders overlay without click handler", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/magic/modal-no-close-host")

      overlay = view |> element("#test-modal-no-close-modal-overlay") |> render()
      refute overlay =~ "phx-click"
    end

    test "defaults still render escape and backdrop handlers", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/magic/modal-host")

      chrome = view |> element("#test-modal-modal") |> render()
      assert chrome =~ ~s(data-close-on-escape="true")

      overlay = view |> element("#test-modal-modal-overlay") |> render()
      assert overlay =~ "phx-click"
    end
  end

  describe "dialog accessibility markup (issue #29)" do
    test "panel renders role=dialog with aria-modal and tabindex", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/magic/modal-host")

      panel = view |> element("#test-modal-modal-panel_content") |> render()
      assert panel =~ ~s(role="dialog")
      assert panel =~ ~s(aria-modal="true")
      assert panel =~ ~s(tabindex="-1")
      # Escape is no longer a server binding on every panel
      refute panel =~ "phx-window-keydown"
    end
  end

  describe "modal render optimization" do
    setup %{conn: conn} do
      # Register the test process so the modal component can find it
      Process.register(self(), :modal_test_pid)

      on_exit(fn ->
        try do
          Process.unregister(:modal_test_pid)
        rescue
          _ -> :ok
        end
      end)

      {:ok, conn: conn}
    end

    test "does not call render function when modal is closed on mount", %{conn: conn} do
      {:ok, _view, _html} = live(conn, "/magic/modal-host")

      # Give a moment for any potential render calls
      refute_receive {:modal_rendered, _}, 100
    end

    test "calls render function when modal is opened", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/magic/modal-host")

      # Open the modal
      view |> element("#open-modal") |> render_click()

      # Should receive a render call with the item_id
      assert_receive {:modal_rendered, "123"}, 100
    end

    test "does not call render function after modal is closed", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/magic/modal-host")

      # Open the modal first
      view |> element("#open-modal") |> render_click()
      assert_receive {:modal_rendered, "123"}, 100

      # Close the modal (click the close button inside the modal)
      view |> element("#modal-content button") |> render_click()

      # Flush any pending messages
      receive do
        {:modal_rendered, nil} -> flunk("Render was called with nil after close")
      after
        100 -> :ok
      end
    end
  end
end
