defmodule Lavash.Optimistic.VersionTest do
  use ExUnit.Case, async: true

  alias Lavash.Optimistic.Version
  alias Lavash.Socket, as: LSocket

  defp init_socket(opts \\ %{}) do
    LSocket.init(%Phoenix.LiveView.Socket{}, opts)
  end

  describe "get/1" do
    test "starts at 0 for a fresh socket" do
      assert Version.get(init_socket()) == 0
    end

    test "reads the initial value passed to Socket.init/2" do
      socket = init_socket(%{optimistic_version: 5})
      assert Version.get(socket) == 5
    end
  end

  describe "bump/1" do
    test "increments by 1" do
      socket = init_socket() |> Version.bump()
      assert Version.get(socket) == 1
    end

    test "bumps sequentially" do
      socket =
        init_socket()
        |> Version.bump()
        |> Version.bump()
        |> Version.bump()

      assert Version.get(socket) == 3
    end
  end

  describe "project/1" do
    test "projects `@__lavash_parent_version__` into assigns" do
      socket = init_socket() |> Version.bump() |> Version.bump()
      projected = Version.project(socket)
      assert projected.assigns.__lavash_parent_version__ == 2
    end

    test "uses 0 for a fresh socket" do
      socket = init_socket() |> Version.project()
      assert socket.assigns.__lavash_parent_version__ == 0
    end
  end
end
