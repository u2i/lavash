defmodule Lavash.Test.Magic.AssignsOnMount do
  @moduledoc """
  Test fixture: a plain Phoenix on_mount hook that plants
  `:current_user` on the socket. Simulates what AshAuthentication's
  `:live_user_required` does — without requiring AshAuthentication.

  We hard-code the user value here. Real on_mount hooks would query
  the database from the session token.
  """

  import Phoenix.Component, only: [assign: 3]

  def on_mount(:default, _params, _session, socket) do
    user = %{id: "u-123", email: "alice@example.com", name: "Alice"}
    {:cont, assign(socket, :current_user, user)}
  end
end

defmodule Lavash.Test.Magic.AssignsLive do
  @moduledoc """
  Test fixture for `from: :assigns` state hydration.

  An on_mount hook (see AssignsOnMount) plants `:current_user` on
  socket.assigns. This LiveView lifts it into lavash state via
  `state :user, :map, from: :assigns, assigns_key: :current_user`,
  so `rx(@user.email)` can drive a calculation.
  """
  use Lavash.LiveView

  on_mount(Lavash.Test.Magic.AssignsOnMount)

  state :user, :map, from: :assigns, assigns_key: :current_user

  # No on_mount → no assign → field falls back to default. This
  # field's default is "guest" so we can prove the fallback path.
  state :missing, :string, from: :assigns, default: "guest"

  calculate :greeting, rx("Hello, " <> @user.name), optimistic: false

  def render(assigns) do
    ~H"""
    <div>
      <p id="user-email">{@user.email}</p>
      <p id="user-name">{@user.name}</p>
      <p id="greeting">{@greeting}</p>
      <p id="missing">{@missing}</p>
    </div>
    """
  end
end
