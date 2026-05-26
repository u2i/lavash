defmodule Lavash.Parity.Lavash.UploadsLive do
  @moduledoc """
  Lavash DSL expression of the uploads parity suite — paired
  with `Lavash.Parity.Vanilla.UploadsLive`.

  ## The gap, concretely

  Lavash doesn't (yet) have DSL surface for
  `Phoenix.LiveView.allow_upload/3`, `consume_uploaded_entries/3`,
  or the `:uploads` assign machinery. Every upload op in this
  file drops to `run fn socket -> ... end` (and the mount uses
  `mount do run fn socket -> allow_upload(socket, ...) end end`).

  Compare:

  Vanilla LV mount:

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

  Lavash equivalent:

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

  Same actions hit the same wall as streams (#52): action
  \`run fn assigns -> ... end\` returns assigns; upload ops return
  a socket; the action runtime drops the changes.

  ## What would close the gap

  A declarative `upload :files, ...` DSL entity that maps onto
  `Phoenix.LiveView.allow_upload/3` and a `consume :files do ...`
  op for the save side. The shape would parallel `form :name`:

      upload :files do
        accept ~w(.txt .md .json)
        max_entries 2
        max_file_size 10_000
      end

      actions do
        action :save do
          consume :files, fn meta, entry -> ... end
        end
      end

  Out of scope tonight; this file uses the escape hatch so the
  parity test demonstrates the gap.
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
      run fn socket ->
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
      run fn socket ->
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
