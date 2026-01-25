defmodule DemoWeb.LiveUserAuth do
  @moduledoc """
  LiveView on_mount hook for loading the current user.

  Provides three hooks:
  - `:live_user_optional` - Loads user if present, nil otherwise
  - `:live_user_required` - Requires a registered (non-anonymous) user
  - `:live_user_ensure` - Ensures a user exists, creating anonymous if needed
  """
  use DemoWeb, :verified_routes

  import Phoenix.Component
  import Phoenix.LiveView

  @doc """
  LiveView on_mount callback with different behaviors based on the hook name:

  - `:live_user_optional` - Loads user if present, nil otherwise
  - `:live_user_required` - Requires a registered (non-anonymous) user, redirects to sign-in otherwise
  - `:live_user_ensure` - Ensures a user exists, creating anonymous if needed
  """
  def on_mount(name, params, session, socket)

  def on_mount(:live_user_optional, _params, session, socket) do
    socket = assign_user_from_session(socket, session)
    {:cont, socket}
  end

  def on_mount(:live_user_required, _params, session, socket) do
    socket = assign_user_from_session(socket, session)

    case socket.assigns.current_user do
      %{anonymous: false} ->
        {:cont, socket}

      _ ->
        socket =
          socket
          |> put_flash(:error, "You must log in to access this page.")
          |> redirect(to: ~p"/sign-in")

        {:halt, socket}
    end
  end

  def on_mount(:live_user_ensure, _params, session, socket) do
    socket = assign_user_from_session(socket, session)

    if socket.assigns.current_user do
      {:cont, socket}
    else
      # Create anonymous user - note: this won't persist to session from LiveView
      # The EnsureUser plug should have already created the user in the HTTP request
      # This is a fallback for edge cases
      case Demo.Accounts.User |> Ash.Changeset.for_create(:create_anonymous) |> Ash.create() do
        {:ok, user} ->
          {:cont, assign(socket, :current_user, user)}

        {:error, _error} ->
          {:cont, assign(socket, :current_user, nil)}
      end
    end
  end

  defp assign_user_from_session(socket, session) do
    assign_new(socket, :current_user, fn ->
      if user_token = session["user_token"] do
        case AshAuthentication.subject_to_user(user_token, Demo.Accounts.User) do
          {:ok, user} -> user
          _ -> nil
        end
      end
    end)
  end
end
