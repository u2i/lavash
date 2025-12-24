defmodule DemoWeb.LiveUserAuth do
  @moduledoc """
  LiveView on_mount hook for loading the current user.
  """
  use DemoWeb, :verified_routes

  import Phoenix.Component
  import Phoenix.LiveView

  def on_mount(:live_user_optional, _params, session, socket) do
    socket =
      socket
      |> assign_new(:current_user, fn ->
        if user_token = session["user_token"] do
          case AshAuthentication.subject_to_user(user_token, Demo.Accounts.User) do
            {:ok, user} -> user
            _ -> nil
          end
        end
      end)

    {:cont, socket}
  end

  def on_mount(:live_user_required, _params, session, socket) do
    socket =
      socket
      |> assign_new(:current_user, fn ->
        if user_token = session["user_token"] do
          case AshAuthentication.subject_to_user(user_token, Demo.Accounts.User) do
            {:ok, user} -> user
            _ -> nil
          end
        end
      end)

    if socket.assigns.current_user do
      {:cont, socket}
    else
      socket =
        socket
        |> put_flash(:error, "You must log in to access this page.")
        |> redirect(to: ~p"/sign-in")

      {:halt, socket}
    end
  end
end
