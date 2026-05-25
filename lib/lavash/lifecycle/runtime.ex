defmodule Lavash.Lifecycle.Runtime do
  @moduledoc """
  Runtime support for lifecycle DSL blocks (`messages do message ...
  end end` today; mount/handle_params/connected blocks if/when they
  land).

  The compiled message clause arrives here with the user's module,
  the post-body socket, and any state fields written via `set`. We
  mark those fields dirty, recompute the reactive graph, and project
  derived values — same discipline `handle_event` ends with.
  """

  alias Lavash.Assigns
  alias Lavash.Reactive
  alias Lavash.Socket, as: LSocket

  @doc """
  Finalises the socket after a `message` clause body has run.

  Marks any fields in `touched_state_fields` as dirty (so the
  reactive graph notices), runs `Reactive.recompute/1`, then
  `Assigns.project/2`. Returns the standard
  `{:noreply, socket}` tuple Phoenix expects.
  """
  def finalize(module, socket, touched_state_fields) do
    state_field_names = LSocket.get(socket, :state_field_names) || MapSet.new()

    socket =
      Enum.reduce(touched_state_fields, socket, fn field, sock ->
        if MapSet.member?(state_field_names, field) do
          LSocket.put_state(sock, field, sock.assigns[field])
        else
          sock
        end
      end)

    socket =
      socket
      |> Reactive.recompute()
      |> Assigns.project(module)

    {:noreply, socket}
  end
end
