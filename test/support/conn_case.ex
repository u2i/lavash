defmodule Lavash.ConnCase do
  @moduledoc """
  Test case for Lavash LiveView integration tests.

  Provides setup for Phoenix.ConnTest and Phoenix.LiveViewTest.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint Lavash.TestEndpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
