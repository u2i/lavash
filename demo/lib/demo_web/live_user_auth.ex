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
  Loads the current user from session if present.
  Does not require a user to be present.
  """
  def on_mount(:live_user_optional, _params, session, socket) do
    socket = assign_user_from_session(socket, session)
    {:cont, socket}
  end

  @doc """
  Requires a registered (non-anonymous) user.
  Redirects to sign-in if no user or user is anonymous.
  """
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

  @doc """
  Ensures a user exists in the session.
  Creates an anonymous user if no user is present.
  This is useful for storefront pages that need a user for cart functionality.
  """
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
