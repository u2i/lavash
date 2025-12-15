defmodule Lavash.Socket do
  @moduledoc """
  Helpers for accessing Lavash private socket data.

  All Lavash internal state is stored in `socket.private.lavash` to avoid
  polluting the assigns namespace and to skip change tracking overhead.
  """

  @doc """
  Initializes the Lavash private data structure on the socket.
  """
  def init(socket, opts \\ %{}) do
    lavash = %{
      state: Map.get(opts, :state, %{}),
      derived: Map.get(opts, :derived, %{}),
      dirty: Map.get(opts, :dirty, MapSet.new()),
      url_changed: Map.get(opts, :url_changed, false),
      socket_changed: Map.get(opts, :socket_changed, false),
      url_fields: Map.get(opts, :url_fields, MapSet.new()),
      socket_fields: Map.get(opts, :socket_fields, MapSet.new()),
      # Route info for URL rebuilding
      route_pattern: Map.get(opts, :route_pattern),
      path_param_names: Map.get(opts, :path_param_names, MapSet.new()),
      # Component-specific
      props: Map.get(opts, :props, %{}),
      component_id: Map.get(opts, :component_id),
      component_states: Map.get(opts, :component_states, %{})
    }

    Phoenix.LiveView.put_private(socket, :lavash, lavash)
  end

  @doc """
  Gets the entire Lavash private data map.
  """
  def get(socket) do
    socket.private[:lavash] || %{}
  end

  @doc """
  Gets a specific key from Lavash private data.
  """
  def get(socket, key) do
    get(socket)[key]
  end

  @doc """
  Puts a value into Lavash private data.
  """
  def put(socket, key, value) do
    lavash = get(socket)
    Phoenix.LiveView.put_private(socket, :lavash, Map.put(lavash, key, value))
  end

  @doc """
  Updates a value in Lavash private data using a function.
  """
  def update(socket, key, fun) do
    lavash = get(socket)
    current = Map.get(lavash, key)
    Phoenix.LiveView.put_private(socket, :lavash, Map.put(lavash, key, fun.(current)))
  end

  # Convenience accessors

  def state(socket), do: get(socket, :state) || %{}
  def derived(socket), do: get(socket, :derived) || %{}
  def dirty(socket), do: get(socket, :dirty) || MapSet.new()
  def dirty?(socket), do: MapSet.size(dirty(socket)) > 0
  def props(socket), do: get(socket, :props) || %{}

  def url_changed?(socket), do: get(socket, :url_changed) == true
  def socket_changed?(socket), do: get(socket, :socket_changed) == true

  def url_field?(socket, field) do
    MapSet.member?(get(socket, :url_fields) || MapSet.new(), field)
  end

  def socket_field?(socket, field) do
    MapSet.member?(get(socket, :socket_fields) || MapSet.new(), field)
  end

  @doc """
  Gets a value from state.
  """
  def get_state(socket, field) do
    Map.get(state(socket), field)
  end

  @doc """
  Gets full state merged with derived values.
  """
  def full_state(socket) do
    Map.merge(state(socket), derived(socket))
  end

  @doc """
  Puts a value into state, marking the field as dirty.
  Also tracks URL/socket changes if applicable.
  """
  def put_state(socket, field, value) do
    current_state = state(socket)
    old_value = Map.get(current_state, field)
    new_state = Map.put(current_state, field, value)

    socket
    |> put(:state, new_state)
    |> update(:dirty, &MapSet.put(&1, field))
    |> maybe_mark_url_changed(field, old_value, value)
    |> maybe_mark_socket_changed(field, old_value, value)
  end

  defp maybe_mark_url_changed(socket, field, old_value, new_value) do
    if url_field?(socket, field) and old_value != new_value do
      put(socket, :url_changed, true)
    else
      socket
    end
  end

  defp maybe_mark_socket_changed(socket, field, old_value, new_value) do
    if socket_field?(socket, field) and old_value != new_value do
      put(socket, :socket_changed, true)
    else
      socket
    end
  end

  @doc """
  Puts a derived value.
  """
  def put_derived(socket, field, value) do
    update(socket, :derived, &Map.put(&1, field, value))
  end

  @doc """
  Clears the dirty set.
  """
  def clear_dirty(socket) do
    put(socket, :dirty, MapSet.new())
  end

  @doc """
  Clears URL changed flag.
  """
  def clear_url_changed(socket) do
    put(socket, :url_changed, false)
  end

  @doc """
  Clears socket changed flag.
  """
  def clear_socket_changed(socket) do
    put(socket, :socket_changed, false)
  end
end
