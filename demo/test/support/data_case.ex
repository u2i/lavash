defmodule Demo.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring access to the
  application's data layer.

  You may define functions here to be used as helpers in your tests.

  Finally, if the test case interacts with the database, we enable the
  SQL sandbox, so changes done to the database are reverted at the end
  of every test. If you are using PostgreSQL, you can even run database
  tests asynchronously by setting `use Demo.DataCase, async: true`,
  although this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Demo.Repo

      import Ecto
      import Ecto.Query
      import Demo.DataCase
    end
  end

  setup tags do
    Demo.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.

  Ownership is shared with all processes (LiveViews, tasks) unless the
  test is async. Ad-hoc `start_owner!(shared: true)` in individual test
  files is a trap — stopping a shared owner leaves the pool in `:manual`
  mode, breaking any later test that relied on `:automatic` checkout.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Demo.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end
end
