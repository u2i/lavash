defmodule Lavash.SocketTest do
  use ExUnit.Case, async: true

  alias Lavash.Socket, as: LSocket

  defp bare_socket do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}},
      private: %{}
    }
  end

  defp init_socket(opts \\ %{}) do
    bare_socket() |> LSocket.init(opts)
  end

  # ============================================
  # init/2
  # ============================================

  describe "init/2" do
    test "initializes lavash private data with defaults" do
      socket = init_socket()
      data = LSocket.get(socket)

      assert data.state_field_names == MapSet.new()
      assert data.dirty == MapSet.new()
      assert data.url_changed == false
      assert data.socket_changed == false
      assert data.optimistic_version == 0
      assert data.registered_components == %{}
    end

    test "accepts custom options" do
      socket =
        init_socket(%{
          url_fields: MapSet.new([:count]),
          socket_fields: MapSet.new([:theme]),
          optimistic_version: 5
        })

      assert LSocket.url_field?(socket, :count)
      assert LSocket.socket_field?(socket, :theme)
      assert Lavash.Optimistic.Version.get(socket) == 5
    end
  end

  # ============================================
  # put_state / get_state
  # ============================================

  describe "put_state/3 and get_state/2" do
    test "stores and retrieves a value" do
      socket = init_socket() |> LSocket.put_state(:count, 42)
      assert LSocket.get_state(socket, :count) == 42
    end

    test "registers the field in state_field_names" do
      socket = init_socket() |> LSocket.put_state(:count, 0)
      assert MapSet.member?(LSocket.get(socket, :state_field_names), :count)
    end

    test "marks field as dirty" do
      socket = init_socket() |> LSocket.put_state(:count, 1)
      assert MapSet.member?(LSocket.dirty(socket), :count)
    end

    test "marks url_changed when url_field value changes" do
      socket =
        init_socket(%{url_fields: MapSet.new([:count])})
        |> LSocket.put_state(:count, 1)

      assert LSocket.url_changed?(socket)
    end

    test "does not mark url_changed for non-url field" do
      socket =
        init_socket(%{url_fields: MapSet.new([:count])})
        |> LSocket.put_state(:other, 1)

      refute LSocket.url_changed?(socket)
    end

    test "marks socket_changed when socket_field value changes" do
      socket =
        init_socket(%{socket_fields: MapSet.new([:theme])})
        |> LSocket.put_state(:theme, "dark")

      assert LSocket.socket_changed?(socket)
    end
  end

  # ============================================
  # put_derived
  # ============================================

  describe "put_derived/3" do
    test "stores and retrieves a derived value" do
      socket = init_socket() |> LSocket.put_derived(:doubled, 10)
      assert socket.assigns[:doubled] == 10
    end

    test "registers field in derived_field_names" do
      socket = init_socket() |> LSocket.put_derived(:doubled, 10)
      assert MapSet.member?(LSocket.get(socket, :derived_field_names), :doubled)
    end

    test "does not mark field as dirty" do
      socket = init_socket() |> LSocket.put_derived(:doubled, 10)
      refute LSocket.dirty?(socket)
    end
  end

  # ============================================
  # state / derived / full_state
  # ============================================

  describe "state/derived/full_state" do
    test "state returns only state fields" do
      socket =
        init_socket()
        |> LSocket.put_state(:count, 5)
        |> LSocket.put_derived(:doubled, 10)

      state = LSocket.state(socket)
      assert state == %{count: 5}
    end

    test "derived returns only derived fields" do
      socket =
        init_socket()
        |> LSocket.put_state(:count, 5)
        |> LSocket.put_derived(:doubled, 10)

      derived = LSocket.derived(socket)
      assert derived == %{doubled: 10}
    end

    test "full_state merges both" do
      socket =
        init_socket()
        |> LSocket.put_state(:count, 5)
        |> LSocket.put_derived(:doubled, 10)

      full = LSocket.full_state(socket)
      assert full == %{count: 5, doubled: 10}
    end
  end

  # ============================================
  # dirty tracking
  # ============================================

  describe "dirty tracking" do
    test "dirty?/1 returns false initially" do
      refute LSocket.dirty?(init_socket())
    end

    test "dirty?/1 returns true after put_state" do
      socket = init_socket() |> LSocket.put_state(:count, 1)
      assert LSocket.dirty?(socket)
    end

    test "mark_dirty/2 adds multiple fields" do
      socket = init_socket() |> LSocket.mark_dirty([:a, :b, :c])
      dirty = LSocket.dirty(socket)
      assert MapSet.member?(dirty, :a)
      assert MapSet.member?(dirty, :b)
      assert MapSet.member?(dirty, :c)
    end

    test "clear_dirty/1 resets to empty" do
      socket =
        init_socket()
        |> LSocket.put_state(:count, 1)
        |> LSocket.clear_dirty()

      refute LSocket.dirty?(socket)
    end
  end

  # ============================================
  # flag management
  # ============================================

  describe "flag management" do
    test "clear_url_changed/1 resets flag" do
      socket =
        init_socket(%{url_fields: MapSet.new([:count])})
        |> LSocket.put_state(:count, 1)
        |> LSocket.clear_url_changed()

      refute LSocket.url_changed?(socket)
    end

    test "clear_socket_changed/1 resets flag" do
      socket =
        init_socket(%{socket_fields: MapSet.new([:theme])})
        |> LSocket.put_state(:theme, "dark")
        |> LSocket.clear_socket_changed()

      refute LSocket.socket_changed?(socket)
    end
  end

  # ============================================
  # component registration
  # ============================================

  describe "component registration" do
    test "register_component/4 and registered_components/1" do
      socket =
        init_socket()
        |> LSocket.register_component("cart-1", CartComponent, [:cart_item])

      components = LSocket.get(socket, :registered_components)
      assert components["cart-1"] == {CartComponent, [:cart_item]}
    end
  end
end
