defmodule Lavash.Component.Runtime do
  @moduledoc """
  Runtime implementation for Lavash Components.

  Handles:
  - Props from parent
  - Internal socket/ephemeral state
  - Derived state computation
  - Action execution
  - Assign projection
  """

  alias Lavash.Graph
  alias Lavash.Assigns

  def update(module, assigns, socket) do
    socket =
      if first_mount?(socket) do
        # First mount - initialize everything
        socket
        |> init_lavash_state(module, assigns)
        |> hydrate_socket_state(module, assigns)
        |> hydrate_ephemeral(module)
        |> store_props(module, assigns)
        |> preserve_livecomponent_assigns(assigns)
        |> Graph.recompute_all(module)
        |> Assigns.project(module)
      else
        # Subsequent update - just update props and recompute
        socket
        |> store_props(module, assigns)
        |> preserve_livecomponent_assigns(assigns)
        |> Graph.recompute_all(module)
        |> Assigns.project(module)
      end

    {:ok, socket}
  end

  def handle_event(module, event, params, socket) do
    action_name = String.to_existing_atom(event)
    actions = module.__lavash__(:actions)

    case Enum.find(actions, &(&1.name == action_name)) do
      nil ->
        {:noreply, socket}

      action ->
        socket =
          socket
          |> execute_action(module, action, params)
          |> maybe_sync_socket_state(module)
          |> Graph.recompute_dirty(module)
          |> Assigns.project(module)

        {:noreply, socket}
    end
  end

  # Private

  defp first_mount?(socket) do
    not Map.has_key?(socket.assigns, :__lavash_state__)
  end

  defp init_lavash_state(socket, module, assigns) do
    socket_field_names =
      module.__lavash__(:socket_fields)
      |> Enum.map(& &1.name)
      |> MapSet.new()

    # Component ID for namespacing socket state
    component_id = Map.get(assigns, :id, "unknown")

    socket
    |> Phoenix.Component.assign(:__lavash_state__, %{})
    |> Phoenix.Component.assign(:__lavash_props__, %{})
    |> Phoenix.Component.assign(:__lavash_derived__, %{})
    |> Phoenix.Component.assign(:__lavash_dirty__, MapSet.new())
    |> Phoenix.Component.assign(:__lavash_socket_changed__, false)
    |> Phoenix.Component.assign(:__lavash_socket_fields__, socket_field_names)
    |> Phoenix.Component.assign(:__lavash_component_id__, component_id)
  end

  defp hydrate_socket_state(socket, module, assigns) do
    socket_fields = module.__lavash__(:socket_fields)
    component_id = Map.get(assigns, :id, "unknown")

    # Get initial state from parent via __lavash_initial_state__ prop
    # This is populated by the parent LiveView from connect_params
    client_state = Map.get(assigns, :__lavash_initial_state__, %{})

    state =
      Enum.reduce(socket_fields, socket.assigns.__lavash_state__, fn field, state ->
        key = to_string(field.name)
        raw_value = Map.get(client_state, key)

        value =
          cond do
            not Map.has_key?(client_state, key) -> field.default
            is_nil(raw_value) -> field.default
            raw_value == "" and field.type != :string -> field.default
            true -> decode_type(raw_value, field.type)
          end

        Map.put(state, field.name, value)
      end)

    Phoenix.Component.assign(socket, :__lavash_state__, state)
  end

  defp preserve_livecomponent_assigns(socket, assigns) do
    # Preserve LiveComponent built-in assigns
    # Note: :myself is reserved and auto-assigned by LiveView, so we don't set it
    Phoenix.Component.assign(socket, :id, Map.get(assigns, :id))
  end

  defp hydrate_ephemeral(socket, module) do
    ephemeral_fields = module.__lavash__(:ephemeral_fields)

    state =
      Enum.reduce(ephemeral_fields, socket.assigns.__lavash_state__, fn field, state ->
        if Map.has_key?(state, field.name) do
          state
        else
          Map.put(state, field.name, field.default)
        end
      end)

    Phoenix.Component.assign(socket, :__lavash_state__, state)
  end

  defp store_props(socket, module, assigns) do
    props = module.__lavash__(:props)

    prop_values =
      Enum.reduce(props, %{}, fn prop, acc ->
        value =
          case Map.fetch(assigns, prop.name) do
            {:ok, val} -> val
            :error when prop.required -> raise "Required prop #{prop.name} not provided"
            :error -> prop.default
          end

        Map.put(acc, prop.name, value)
      end)

    # Store props separately and also merge into state for derived field access
    socket
    |> Phoenix.Component.assign(:__lavash_props__, prop_values)
    |> update_state_with_props(prop_values)
  end

  defp update_state_with_props(socket, prop_values) do
    # Merge props into state so derived fields can depend on them
    state = Map.merge(socket.assigns.__lavash_state__, prop_values)
    Phoenix.Component.assign(socket, :__lavash_state__, state)
  end

  defp execute_action(socket, module, action, event_params) do
    params =
      Enum.reduce(action.params, %{}, fn param, acc ->
        key = to_string(param)
        Map.put(acc, param, Map.get(event_params, key))
      end)

    if guards_pass?(socket, module, action.when) do
      socket
      |> apply_sets(action.sets || [], params)
      |> apply_updates(action.updates || [], params)
      |> apply_effects(action.effects || [], params)
    else
      socket
    end
  end

  defp guards_pass?(socket, _module, guards) do
    state = get_full_state(socket)
    Enum.all?(guards, fn guard -> Map.get(state, guard) == true end)
  end

  defp apply_sets(socket, sets, params) do
    Enum.reduce(sets, socket, fn set, sock ->
      value =
        case set.value do
          fun when is_function(fun, 1) ->
            fun.(%{params: params, state: get_state(sock)})
          value ->
            value
        end

      put_state(sock, set.field, value)
    end)
  end

  defp apply_updates(socket, updates, _params) do
    Enum.reduce(updates, socket, fn update, sock ->
      current = get_state(sock, update.field)
      new_value = update.fun.(current)
      put_state(sock, update.field, new_value)
    end)
  end

  defp apply_effects(socket, effects, _params) do
    state = get_full_state(socket)
    Enum.each(effects, fn effect -> effect.fun.(state) end)
    socket
  end

  defp maybe_sync_socket_state(socket, module) do
    if socket.assigns.__lavash_socket_changed__ do
      socket_fields = module.__lavash__(:socket_fields)
      state = socket.assigns.__lavash_state__
      component_id = socket.assigns.__lavash_component_id__

      socket_state =
        Enum.reduce(socket_fields, %{}, fn field, acc ->
          value = Map.get(state, field.name)
          Map.put(acc, to_string(field.name), value)
        end)

      # Push component state to JS, namespaced by component ID
      socket
      |> Phoenix.Component.assign(:__lavash_socket_changed__, false)
      |> Phoenix.LiveView.push_event("_lavash_component_sync", %{
        id: component_id,
        state: socket_state
      })
    else
      socket
    end
  end

  defp get_state(socket) do
    socket.assigns.__lavash_state__
  end

  defp get_state(socket, field) do
    Map.get(socket.assigns.__lavash_state__, field)
  end

  defp get_full_state(socket) do
    Map.merge(socket.assigns.__lavash_state__, socket.assigns.__lavash_derived__)
  end

  defp put_state(socket, field, value) do
    state = socket.assigns.__lavash_state__
    old_value = Map.get(state, field)

    socket = Phoenix.Component.assign(socket, :__lavash_state__, Map.put(state, field, value))

    socket =
      Phoenix.Component.assign(
        socket,
        :__lavash_dirty__,
        MapSet.put(socket.assigns.__lavash_dirty__, field)
      )

    # Check if this is a socket field (not a prop or ephemeral)
    if socket_field?(socket, field) and old_value != value do
      Phoenix.Component.assign(socket, :__lavash_socket_changed__, true)
    else
      socket
    end
  end

  defp socket_field?(socket, field) do
    MapSet.member?(socket.assigns.__lavash_socket_fields__, field)
  end

  defp decode_type(value, :string), do: value
  defp decode_type(value, :integer) when is_integer(value), do: value
  defp decode_type(value, :integer), do: String.to_integer(value)
  defp decode_type("true", :boolean), do: true
  defp decode_type("false", :boolean), do: false
  defp decode_type(value, :boolean) when is_boolean(value), do: value
  defp decode_type(value, :boolean), do: !!value
  defp decode_type(value, _type), do: value
end
