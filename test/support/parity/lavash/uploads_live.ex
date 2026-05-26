defmodule Lavash.Parity.Lavash.UploadsLive do
  @moduledoc """
  Lavash DSL expression of the uploads parity suite — paired
  with `Lavash.Parity.Vanilla.UploadsLive`.

  ## Now using `socket_run`

  Earlier versions of this fixture wrapped upload ops in
  `run fn socket -> ... end` and were tagged `:parity_gap`
  because the assigns-shaped `run` dropped socket-level changes.
  With `socket_run` (the socket-shaped action op) the gap closes
  — the action body returns a socket and the runtime accepts it
  wholesale.

  ## Still missing — a declarative `upload :files` flavor

  This fixture works today but it's verbose. A future
  `upload :files do accept ..., max_entries 2 end` declaration
  plus a `consume :files, fn meta, entry -> ... end` op would
  let this collapse to declarative DSL. Out of scope for the
  parity test; the gap is in the verbosity, not the
  functionality.
  """
  use Lavash.LiveView

  state :status, :string, default: "idle"

  mount do
    run fn socket ->
      Phoenix.LiveView.allow_upload(socket, :files,
        accept: ~w(.txt .md .json),
        max_entries: 2,
        max_file_size: 10_000
      )
    end
  end

  actions do
    action :validate do
      # no-op; just acknowledges phx-change
    end

    action :save do
      socket_run fn socket ->
        Phoenix.LiveView.consume_uploaded_entries(socket, :files, fn meta, entry ->
          contents = File.read!(meta.path)
          Lavash.Parity.UploadSink.record(entry.client_name, contents)
          {:ok, entry.client_name}
        end)

        socket
      end

      set :status, "saved"
    end

    action :cancel, [:ref] do
      socket_run fn socket ->
        Phoenix.LiveView.cancel_upload(socket, :files, socket.assigns.ref)
      end
    end
  end

  template do
    ~H"""
    <div id="uploads-lavash">
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
