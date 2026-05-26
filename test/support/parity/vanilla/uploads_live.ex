defmodule Lavash.Parity.Vanilla.UploadsLive do
  @moduledoc """
  Vanilla `Phoenix.LiveView` reference for the uploads parity
  suite.

  Exercises the core upload flow:

    * `allow_upload/3` — declare a named upload at mount with
      constraints (max_entries, max_file_size, accept)
    * Rendering the `@uploads.<name>` config to drive the file
      picker
    * `phx-change="validate"` to react to file selection
    * `consume_uploaded_entries/3` on submit — copies the upload
      from the temp location to its final home (in-memory ETS
      for this test, not the filesystem)

  ## Why an ETS sink

  Real apps write to disk or S3. For a parity test we want
  deterministic, side-effect-free verification, so the
  `consume` callback writes to a public ETS table keyed by
  entry filename. The test reads back from there.
  """
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:status, "idle")
      |> allow_upload(:files,
        accept: ~w(.txt .md .json),
        max_entries: 2,
        max_file_size: 10_000
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("save", _params, socket) do
    consume_uploaded_entries(socket, :files, fn meta, entry ->
      contents = File.read!(meta.path)
      Lavash.Parity.UploadSink.record(entry.client_name, contents)
      {:ok, entry.client_name}
    end)

    {:noreply, assign(socket, :status, "saved")}
  end

  @impl true
  def handle_event("cancel", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :files, ref)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="uploads-vanilla">
      <p id="status">{@status}</p>

      <form
        id="upload-form"
        phx-submit="save"
        phx-change="validate"
      >
        <.live_file_input upload={@uploads.files} />

        <ul id="entries">
          <li :for={entry <- @uploads.files.entries} id={"entry-" <> entry.ref}>
            <span class="name">{entry.client_name}</span>
            <span class="progress">{entry.progress}%</span>
            <button
              type="button"
              class="cancel"
              phx-click="cancel"
              phx-value-ref={entry.ref}
            >cancel</button>
          </li>
        </ul>

        <p :for={err <- upload_errors(@uploads.files)} class="error">
          {error_to_string(err)}
        </p>

        <button type="submit" id="save">save</button>
      </form>
    </div>
    """
  end

  defp error_to_string(:too_large), do: "file too large"
  defp error_to_string(:not_accepted), do: "wrong file type"
  defp error_to_string(:too_many_files), do: "too many files"
  defp error_to_string(err), do: inspect(err)
end
