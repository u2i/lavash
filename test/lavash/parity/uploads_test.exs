defmodule Lavash.Parity.UploadsTest do
  @moduledoc """
  Parity suite: `Phoenix.LiveView.allow_upload/3` +
  `consume_uploaded_entries/3`.

  Uploads are a substantial LV primitive: the `:uploads` assign,
  client-side file picker integration via `live_file_input/1`,
  validation via `phx-change`, progress tracking, and finally
  `consume_uploaded_entries/3` on submit which moves the
  temp-file contents wherever the app wants them.

  ## Lavash status

  Lavash doesn't yet expose `upload :name` as DSL surface. Both
  fixtures use raw `Phoenix.LiveView.allow_upload/3` — the
  vanilla side directly, the lavash side via
  `mount do run fn socket -> ... end end` and
  `action :save do socket_run fn socket -> ... end end`.

  The `socket_run` action op (the socket-shaped variant of
  `run`) closes what was previously a parity gap by letting
  action bodies return a mutated socket wholesale rather than
  going through the change-tracked `assigns -> assigns`
  contract.

  A future `upload :name` DSL entity would still let this
  collapse from `socket_run` bodies to declarative ops, but
  behavior-wise the parity test passes today.
  """
  use Lavash.ConnCase, async: true

  alias Lavash.Parity.UploadSink

  setup do
    UploadSink.setup()
    :ok
  end

  describe "allow_upload + consume_uploaded_entries (vanilla)" do
    test "mount + render shows the upload form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/parity/vanilla/uploads")

      assert html =~ "upload-form"
      assert html =~ ~s(id="status")
      assert html =~ "idle"
    end

    test "uploading a file and saving consumes via the sink", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/parity/vanilla/uploads")

      file =
        file_input(view, "#upload-form", :files, [
          %{
            name: "hello.txt",
            content: "hello world",
            type: "text/plain"
          }
        ])

      render_upload(file, "hello.txt")

      view |> element("#upload-form") |> render_submit()

      assert {:ok, "hello world"} = UploadSink.get("hello.txt")
      assert render(view) =~ "saved"
    end
  end

  describe "allow_upload + consume_uploaded_entries (lavash)" do
    test "mount + render shows the upload form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/parity/lavash/uploads")

      assert html =~ "upload-form"
      assert html =~ ~s(id="status")
      assert html =~ "idle"
    end

    test "uploading a file and saving consumes via the sink",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/parity/lavash/uploads")

      file =
        file_input(view, "#upload-form", :files, [
          %{
            name: "hello.txt",
            content: "hello world",
            type: "text/plain"
          }
        ])

      render_upload(file, "hello.txt")

      view |> element("#upload-form") |> render_submit()

      assert {:ok, "hello world"} = UploadSink.get("hello.txt")
      assert render(view) =~ "saved"
    end
  end
end
