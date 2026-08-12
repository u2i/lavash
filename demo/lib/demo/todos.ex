defmodule Demo.Todos do
  @moduledoc """
  Domain for the streamed todo demo (lavash issues #70/#71) — a
  stream-backed `client_state` projection with the full optimistic
  row-op family.
  """
  use Ash.Domain

  resources do
    resource Demo.Todos.Todo
  end
end
