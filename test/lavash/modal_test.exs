defmodule Lavash.ModalTest do
  use Lavash.ConnCase, async: false

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
      {:ok, _view, _html} = live(conn, "/modal-host")

      # Give a moment for any potential render calls
      refute_receive {:modal_rendered, _}, 100
    end

    test "calls render function when modal is opened", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/modal-host")

      # Open the modal
      view |> element("#open-modal") |> render_click()

      # Should receive a render call with the item_id
      assert_receive {:modal_rendered, "123"}, 100
    end

    test "does not call render function after modal is closed", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/modal-host")

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
