defmodule Demo.Accounts.Senders.SendPasswordResetEmail do
  @moduledoc """
  Sends a password reset email. For demo purposes, just logs the reset URL.
  """
  use AshAuthentication.Sender

  @impl true
  def send(user, token, _opts) do
    IO.puts("""
    ==============================
    Password Reset for #{user.email}
    Reset URL: /password-reset/#{token}
    ==============================
    """)
  end
end
