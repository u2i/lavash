defmodule Demo.Todos do
  @moduledoc """
  Domain for the streamed todo demo (lavash issues #70/#71) — a
  stream-backed `client_state` projection with the full optimistic
  row-op family.
  """
  use Ash.Domain

  require Ash.Query

  resources do
    resource Demo.Todos.Todo
  end

  @doc """
  Deletes every todo the user owns and broadcasts invalidation so
  open sessions re-read. Backs the demo's Reset dev tool.
  """
  def wipe_for_user!(user_id) do
    Demo.Todos.Todo
    |> Ash.Query.for_read(:for_user, %{user_id: user_id})
    |> Ash.read!()
    |> Enum.each(&Ash.destroy!/1)

    Lavash.PubSub.broadcast(Demo.Todos.Todo)
    :ok
  end
end
