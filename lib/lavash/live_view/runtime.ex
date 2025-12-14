defmodule Lavash.LiveView.Runtime do
  @moduledoc """
  Runtime implementation for Lavash LiveViews.

  Handles:
  - State hydration from URL params
  - Ephemeral state initialization
  - Dependency graph computation
  - Action execution
  - Assign projection
  """

  alias Lavash.State
  alias Lavash.Graph
  alias Lavash.Assigns

  def mount(module, _params, _session, socket) do
    # Get connect params if available (contains client-synced socket state)
    connect_params =
      if Phoenix.LiveView.connected?(socket) do
        Phoenix.LiveView.get_connect_params(socket) || %{}
      else
        %{}
      end

    IO.puts("[Lavash] mount connect_params: #{inspect(connect_params)}")

    socket =
      socket
      |> init_lavash_state(module)
      |> State.hydrate_socket(module, connect_params)
      |> State.hydrate_ephemeral(module)

    {:ok, socket}
  end

  def handle_params(module, params, uri, socket) do
    # Store the current path for later push_patch calls
    path = URI.parse(uri).path || "/"

    socket =
      socket
      |> Phoenix.Component.assign(:__lavash_path__, path)
      |> State.hydrate_url(module, params)
      |> Graph.recompute_all(module)
      |> Assigns.project(module)

    {:noreply, socket}
  end

  def handle_event(module, event, params, socket) do
    action_name = String.to_existing_atom(event)
    actions = module.__lavash__(:actions)

    case Enum.find(actions, &(&1.name == action_name)) do
      nil ->
        # No matching action, let it fall through
        {:noreply, socket}

      action ->
        socket =
          socket
          |> execute_action(module, action, params)
          |> maybe_push_patch(module)
          |> maybe_sync_socket_state(module)
          |> Graph.recompute_dirty(module)
          |> Assigns.project(module)

        {:noreply, socket}
    end
  end

  def handle_info(module, {:lavash_async, field, result}, socket) do
    socket =
      socket
      |> put_derived_result(field, result)
      |> Graph.recompute_dependents(module, field)
      |> Assigns.project(module)

    {:noreply, socket}
  end

  def handle_info(_module, _msg, socket) do
    {:noreply, socket}
  end

  # Private

  defp init_lavash_state(socket, module) do
    url_field_names =
      module.__lavash__(:url_fields)
      |> Enum.map(& &1.name)
      |> MapSet.new()

    socket_field_names =
      module.__lavash__(:socket_fields)
      |> Enum.map(& &1.name)
      |> MapSet.new()

    socket
    |> Phoenix.Component.assign(:__lavash_state__, %{})
    |> Phoenix.Component.assign(:__lavash_derived__, %{})
    |> Phoenix.Component.assign(:__lavash_dirty__, MapSet.new())
    |> Phoenix.Component.assign(:__lavash_url_changed__, false)
    |> Phoenix.Component.assign(:__lavash_socket_changed__, false)
    |> Phoenix.Component.assign(:__lavash_url_fields__, url_field_names)
    |> Phoenix.Component.assign(:__lavash_socket_fields__, socket_field_names)
  end

  defp execute_action(socket, module, action, event_params) do
    # Build params map from event
    params =
      Enum.reduce(action.params, %{}, fn param, acc ->
        key = to_string(param)
        Map.put(acc, param, Map.get(event_params, key))
      end)

    # Check guards
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

  defp maybe_push_patch(socket, module) do
    if socket.assigns.__lavash_url_changed__ do
      url_fields = module.__lavash__(:url_fields)
      state = socket.assigns.__lavash_state__
      path = socket.assigns[:__lavash_path__] || "/"

      params =
        Enum.reduce(url_fields, %{}, fn field, acc ->
          value = Map.get(state, field.name)

          if value != nil and value != field.default do
            encoded =
              if field.encode do
                field.encode.(value)
              else
                to_string(value)
              end

            Map.put(acc, to_string(field.name), encoded)
          else
            acc
          end
        end)

      url =
        if params == %{} do
          path
        else
          path <> "?" <> URI.encode_query(params)
        end

      socket
      |> Phoenix.Component.assign(:__lavash_url_changed__, false)
      |> Phoenix.LiveView.push_patch(to: url)
    else
      socket
    end
  end

  defp maybe_sync_socket_state(socket, module) do
    if socket.assigns.__lavash_socket_changed__ do
      socket_fields = module.__lavash__(:socket_fields)
      state = socket.assigns.__lavash_state__

      # Build the socket state map to send to client
      socket_state =
        Enum.reduce(socket_fields, %{}, fn field, acc ->
          value = Map.get(state, field.name)
          Map.put(acc, to_string(field.name), encode_value(value, field.type))
        end)

      IO.puts("[Lavash] syncing socket state to client: #{inspect(socket_state)}")

      socket
      |> Phoenix.Component.assign(:__lavash_socket_changed__, false)
      |> Phoenix.LiveView.push_event("_lavash_sync", socket_state)
    else
      socket
    end
  end

  defp encode_value(value, _type), do: value

  defp put_derived_result(socket, field, result) do
    derived = socket.assigns.__lavash_derived__
    Phoenix.Component.assign(socket, :__lavash_derived__, Map.put(derived, field, {:ok, result}))
  end

  # State access helpers

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

    # Mark dirty and track URL/socket changes
    socket =
      Phoenix.Component.assign(
        socket,
        :__lavash_dirty__,
        MapSet.put(socket.assigns.__lavash_dirty__, field)
      )

    # Check if this is a URL field
    socket =
      if url_field?(socket, field) and old_value != value do
        Phoenix.Component.assign(socket, :__lavash_url_changed__, true)
      else
        socket
      end

    # Check if this is a socket field
    if socket_field?(socket, field) and old_value != value do
      Phoenix.Component.assign(socket, :__lavash_socket_changed__, true)
    else
      socket
    end
  end

  defp url_field?(socket, field) do
    MapSet.member?(socket.assigns.__lavash_url_fields__, field)
  end

  defp socket_field?(socket, field) do
    MapSet.member?(socket.assigns.__lavash_socket_fields__, field)
  end
end
