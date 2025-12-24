defmodule Demo.Accounts.Token do
  use Ash.Resource,
    domain: Demo.Accounts,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshAuthentication.TokenResource]

  sqlite do
    table "tokens"
    repo Demo.Repo
  end

  actions do
    defaults [:read, :destroy]
  end
end
