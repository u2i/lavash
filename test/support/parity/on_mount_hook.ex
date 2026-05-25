defmodule Lavash.Parity.OnMountHook do
  @moduledoc """
  Plain-Elixir `on_mount` hook shared between the vanilla and
  lavash parity fixtures. Demonstrates the common shapes:

    * `:require_user` — proceed if session has a user id; halt
      with a redirect otherwise
    * `:audit` — pass-through hook that just stamps the mount
      time into assigns

  Both fixtures install the same hook the same way (via
  `Phoenix.LiveView.on_mount/1`); parity is verified by
  asserting the same observable outcome on both routes.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [redirect: 2]

  def on_mount(:require_user, _params, session, socket) do
    case Map.get(session, "user_id") do
      nil ->
        {:halt, redirect(socket, to: "/parity/login")}

      user_id ->
        # In a real app this would fetch from the DB. For parity
        # we just expose the id as an assign.
        socket =
          socket
          |> assign(:current_user_id, user_id)
          |> assign(:current_user_email, user_id <> "@example.com")

        {:cont, socket}
    end
  end

  def on_mount(:audit, _params, _session, socket) do
    {:cont, assign(socket, :audited_at, System.system_time(:second))}
  end
end
