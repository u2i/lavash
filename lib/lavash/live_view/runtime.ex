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
  alias Lavash.Type
  alias Lavash.Socket, as: LSocket

  def mount(module, _params, _session, socket) do
    # Get connect params if available (contains client-synced socket state)
    connect_params =
      if Phoenix.LiveView.connected?(socket) do
        Phoenix.LiveView.get_connect_params(socket) || %{}
      else
        %{}
      end

    # Extract component states for child Lavash components
    component_states = get_in(connect_params, ["_lavash_state", "_components"]) || %{}

    url_field_names =
      module.__lavash__(:url_fields)
      |> Enum.map(& &1.name)
      |> MapSet.new()

    socket_field_names =
      module.__lavash__(:socket_fields)
      |> Enum.map(& &1.name)
      |> MapSet.new()

    socket =
      socket
      |> LSocket.init(%{
        url_fields: url_field_names,
        socket_fields: socket_field_names,
        component_states: component_states
      })
      |> State.hydrate_socket(module, connect_params)
      |> State.hydrate_ephemeral(module)

    {:ok, socket}
  end

  def handle_params(module, params, uri, socket) do
    # Store the current path for later push_patch calls
    path = URI.parse(uri).path || "/"

    socket =
      socket
      |> LSocket.put(:path, path)
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
      |> LSocket.put_derived(field, {:ok, result})
      |> Graph.recompute_dependents(module, field)
      |> Assigns.project(module)

    {:noreply, socket}
  end

  def handle_info(_module, _msg, socket) do
    {:noreply, socket}
  end

  # Private

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
    state = LSocket.full_state(socket)
    Enum.all?(guards, fn guard -> Map.get(state, guard) == true end)
  end

  defp apply_sets(socket, sets, params) do
    Enum.reduce(sets, socket, fn set, sock ->
      value =
        case set.value do
          fun when is_function(fun, 1) ->
            fun.(%{params: params, state: LSocket.state(sock)})

          value ->
            value
        end

      LSocket.put_state(sock, set.field, value)
    end)
  end

  defp apply_updates(socket, updates, _params) do
    Enum.reduce(updates, socket, fn update, sock ->
      current = LSocket.get_state(sock, update.field)
      new_value = update.fun.(current)
      LSocket.put_state(sock, update.field, new_value)
    end)
  end

  defp apply_effects(socket, effects, _params) do
    state = LSocket.full_state(socket)
    Enum.each(effects, fn effect -> effect.fun.(state) end)
    socket
  end

  defp maybe_push_patch(socket, module) do
    if LSocket.url_changed?(socket) do
      url_fields = module.__lavash__(:url_fields)
      state = LSocket.state(socket)
      path = LSocket.get(socket, :path) || "/"

      params =
        Enum.reduce(url_fields, %{}, fn field, acc ->
          value = Map.get(state, field.name)

          if value != nil and value != field.default do
            encoded =
              if field.encode do
                field.encode.(value)
              else
                Type.dump(field.type, value)
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
      |> LSocket.clear_url_changed()
      |> Phoenix.LiveView.push_patch(to: url)
    else
      socket
    end
  end

  defp maybe_sync_socket_state(socket, module) do
    if LSocket.socket_changed?(socket) do
      socket_fields = module.__lavash__(:socket_fields)
      state = LSocket.state(socket)

      # Build the socket state map to send to client
      socket_state =
        Enum.reduce(socket_fields, %{}, fn field, acc ->
          value = Map.get(state, field.name)
          Map.put(acc, to_string(field.name), Type.dump(field.type, value))
        end)

      IO.puts("[Lavash] syncing socket state to client: #{inspect(socket_state)}")

      socket
      |> LSocket.clear_socket_changed()
      |> Phoenix.LiveView.push_event("_lavash_sync", socket_state)
    else
      socket
    end
  end
end
