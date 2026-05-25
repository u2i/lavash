defmodule Lavash.Lifecycle.Runtime do
  @moduledoc """
  Runtime support for `handle_info do on ... end end` (and, eventually,
  `mount do`, `handle_params do`, `connected do` — all lifecycle DSL
  blocks).

  The compiled handle_info clause calls back here with the user's
  body function. We do the put_state + recompute + project dance
  that's been the rc.5 boilerplate footgun.
  """

  alias Lavash.Assigns
  alias Lavash.Reactive
  alias Lavash.Socket, as: LSocket

  @doc """
  Dispatch a `handle_info do on ... do <body> end end` clause.

  The compiled clause arrives here with:

    * `module` — the user's LiveView module (for projection)
    * `socket` — the current socket
    * `updated_assigns` — the result of evaluating the user's body
      against `socket.assigns` (Phoenix.Component.assign-marked
      changes already in `__changed__`)

  We extract the changed keys, write each via `LSocket.put_state` so
  the reactive graph notices, then recompute and project.
  """
  def dispatch(module, socket, updated_assigns) do
    changed = Map.get(updated_assigns, :__changed__, %{})

    socket =
      Enum.reduce(changed, socket, fn {field, _marker}, sock ->
        LSocket.put_state(sock, field, Map.get(updated_assigns, field))
      end)

    socket =
      socket
      |> Reactive.recompute()
      |> Assigns.project(module)

    {:noreply, socket}
  end
end
