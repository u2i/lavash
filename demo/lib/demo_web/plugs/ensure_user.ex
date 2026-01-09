defmodule DemoWeb.Plugs.EnsureUser do
  @moduledoc """
  Plug that ensures a user exists in the session.

  If no user is found, creates an anonymous user and stores them in the session.
  This enables features like shopping carts to work before registration.

  The anonymous user can later be "upgraded" to a registered user via the
  `Demo.Accounts.User.register` action.
  """

  import Plug.Conn
  import AshAuthentication.Plug.Helpers

  def init(opts), do: opts

  def call(conn, _opts) do
    # First try to load user from session (this may have been done by load_from_session)
    current_user = conn.assigns[:current_user]

    if current_user do
      # User already loaded, nothing to do
      conn
    else
      # No user in session - create an anonymous user
      case Demo.Accounts.User |> Ash.Changeset.for_create(:create_anonymous) |> Ash.create() do
        {:ok, user} ->
          conn
          |> store_in_session(user)
          |> assign(:current_user, user)

        {:error, error} ->
          require Logger
          Logger.error("Failed to create anonymous user: #{inspect(error)}")
          conn
      end
    end
  end
end
