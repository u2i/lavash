defmodule Lavash.Optimistic.Version do
  @moduledoc """
  Layer-4 (optimism) version counter.

  Tracks a monotonic version per LiveView socket that the client
  uses to reject stale DOM patches. The counter bumps on each event
  that may trigger an optimistic update; the rendered HTML carries
  the current version, and `Lavash.Assigns.project/2` exposes it to
  child components as `@__lavash_parent_version__` so they can
  cross-check parent identity when reconciling bindings.

  ## Storage

  The value lives in `socket.private[:lavash].optimistic_version`
  for historical compatibility — `Lavash.Socket.init/2` still
  declares the key. This module owns the **read/write API**, which
  is the layering concern; the storage location is a refactor for
  another day.

  ## Why this is its own module

  Per the architecture audit (`docs/ARCHITECTURE.md` punchlist
  item #1), the version counter is purely a layer-4 (optimism)
  concept. Stale-patch rejection only makes sense when there are
  client-side optimistic patches in flight. Keeping the API in
  `Lavash.Socket` (layer 2) meant the layer-2 surface advertised an
  optimism primitive even when no optimistic state existed in the
  module.
  """

  alias Lavash.Socket, as: LSocket

  @doc """
  Returns the socket's current optimistic version (0 if unset).
  """
  def get(socket), do: LSocket.get(socket, :optimistic_version) || 0

  @doc """
  Bumps the optimistic version counter.

  Called when processing an event that triggers optimistic updates.
  The version is included in the rendered HTML and compared by the
  client to detect and reject stale DOM patches.
  """
  def bump(socket) do
    LSocket.update(socket, :optimistic_version, &((&1 || 0) + 1))
  end

  @doc """
  Projects the version into assigns as `@__lavash_parent_version__`.

  Child components compare this against the parent identity they
  saw at mount; on mismatch they re-hydrate optimistic state from
  the parent's authoritative values. Called from
  `Lavash.Assigns.project/2`.
  """
  def project(socket) do
    Phoenix.Component.assign(socket, :__lavash_parent_version__, get(socket))
  end
end
