defmodule Demo.Repo do
  use Ecto.Repo,
    otp_app: :demo,
    adapter: Ecto.Adapters.SQLite3

  def installed_extensions do
    []
  end
end
