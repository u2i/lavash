defmodule Lavash.Socket do
  @moduledoc """
  Helpers for accessing Lavash private socket data.

  Both state and derived values live in `socket.assigns` (leveraging Phoenix change tracking).
  Metadata (dirty set, field name sets, flags) lives in `socket.private.lavash`.
  """

  @doc """
  Initializes the Lavash private data structure on the socket.
  """
  def init(socket, opts \\ %{}) do
    lavash = %{
      state_field_names: Map.get(opts, :state_field_names, MapSet.new()),
      derived_field_names: Map.get(opts, :derived_field_names, MapSet.new()),
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
      component_states: Map.get(opts, :component_states, %{}),
      # Registered child components: %{id => {module, resources}}
      registered_components: Map.get(opts, :registered_components, %{}),
      # Optimistic update version counter - used to reject stale DOM patches
      optimistic_version: Map.get(opts, :optimistic_version, 0)
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

  def state(socket) do
    field_names = get(socket, :state_field_names) || MapSet.new()
    Map.take(socket.assigns, MapSet.to_list(field_names))
  end
  def derived(socket) do
    field_names = get(socket, :derived_field_names) || MapSet.new()
    Map.take(socket.assigns, MapSet.to_list(field_names))
  end
  def dirty(socket), do: get(socket, :dirty) || MapSet.new()
  def dirty?(socket), do: MapSet.size(dirty(socket)) > 0
  def props(socket), do: get(socket, :props) || %{}

  def url_changed?(socket), do: get(socket, :url_changed) == true
  def socket_changed?(socket), do: get(socket, :socket_changed) == true
  def optimistic_version(socket), do: get(socket, :optimistic_version) || 0

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
    socket.assigns[field]
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
  Eagerly writes to assigns so projection is not needed.
  """
  def put_state(socket, field, value) do
    old_value = socket.assigns[field]

    socket
    |> register_state_field(field)
    |> Phoenix.Component.assign(field, value)
    |> update(:dirty, &MapSet.put(&1, field))
    |> maybe_mark_url_changed(field, old_value, value)
    |> maybe_mark_socket_changed(field, old_value, value)
  end

  defp register_state_field(socket, field) do
    update(socket, :state_field_names, fn names ->
      MapSet.put(names || MapSet.new(), field)
    end)
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
  Puts a derived value directly into assigns.
  Raw values (including Lavash.Form, AsyncResult) are stored as-is.
  """
  def put_derived(socket, field, value) do
    socket
    |> register_derived_field(field)
    |> Phoenix.Component.assign(field, value)
  end

  defp register_derived_field(socket, field) do
    update(socket, :derived_field_names, fn names ->
      MapSet.put(names || MapSet.new(), field)
    end)
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

  @doc """
  Marks fields as dirty.
  """
  def mark_dirty(socket, fields) when is_list(fields) do
    update(socket, :dirty, fn dirty ->
      Enum.reduce(fields, dirty, &MapSet.put(&2, &1))
    end)
  end

  @doc """
  Registers a child component for invalidation forwarding.
  """
  def register_component(socket, id, module, resources) do
    update(socket, :registered_components, fn components ->
      Map.put(components || %{}, id, {module, resources})
    end)
  end

  @doc """
  Bumps the optimistic version counter.

  Called when processing an event that triggers optimistic updates.
  The version is included in the rendered HTML and compared by the client
  to detect and reject stale DOM patches.
  """
  def bump_optimistic_version(socket) do
    update(socket, :optimistic_version, &((&1 || 0) + 1))
  end

  @doc """
  Gets all registered components.
  """
  def registered_components(socket) do
    get(socket, :registered_components) || %{}
  end
end
