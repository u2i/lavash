defmodule Lavash.Lifecycle.Runtime do
  @moduledoc """
  Runtime support for lifecycle DSL blocks (`messages do message ...
  end end` today; mount/handle_params/connected blocks if/when they
  land).

  The compiled clause arrives here with the already-mutated socket
  (the user's body returned it). We mark the dirty fields, recompute
  the reactive graph, and project derived values into assigns.

  The discipline matches what the action runtime does at the end of
  every `handle_event` — putting all the post-handler bookkeeping
  in one place so users don't have to remember it.
  """

  alias Lavash.Assigns
  alias Lavash.Reactive
  alias Lavash.Socket, as: LSocket

  @doc """
  Dispatch a `message` clause result.

  Takes the user's module (for projection) and the socket their
  body returned. Walks `socket.assigns.__changed__` to find which
  state fields were touched, marks them dirty in the LSocket state
  registry so the reactive graph notices, then recomputes and
  projects.

  Returns the standard `{:noreply, socket}` tuple Phoenix expects.
  """
  def dispatch(module, socket) do
    changed = Map.get(socket.assigns, :__changed__, %{})

    # Re-mark dirty state fields so Lavash.Reactive picks them up
    # for downstream calculation recompute. Touching `socket.assigns`
    # directly via Phoenix.Component.assign already updated the
    # assigns map, but the LSocket dirty-tracking lives separately
    # and only `put_state` writes to it.
    state_field_names = LSocket.get(socket, :state_field_names) || MapSet.new()

    socket =
      Enum.reduce(changed, socket, fn {field, _marker}, sock ->
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
