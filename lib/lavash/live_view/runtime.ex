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
    parsed_uri = URI.parse(uri)
    path = parsed_uri.path || "/"

    # Introspect the router to get route pattern and path param names
    # This allows us to rebuild URLs with updated path params
    {route_pattern, path_param_names, path_param_values} =
      case get_route_info(socket, path) do
        {:ok, route, path_params} ->
          names = path_params |> Map.keys() |> Enum.map(&String.to_atom/1) |> MapSet.new()
          # Store the actual values for params not in DSL
          values = for {k, v} <- path_params, into: %{}, do: {String.to_atom(k), v}
          {route, names, values}

        :error ->
          # Fallback: no route introspection available
          {path, MapSet.new(), %{}}
      end

    socket =
      socket
      |> LSocket.put(:path, path)
      |> LSocket.put(:route_pattern, route_pattern)
      |> LSocket.put(:path_param_names, path_param_names)
      |> LSocket.put(:path_param_values, path_param_values)
      |> State.hydrate_url(module, params)
      |> Graph.recompute_all(module)
      |> Assigns.project(module)

    {:noreply, socket}
  end

  defp get_route_info(socket, path) do
    router = socket.router

    case Phoenix.Router.route_info(router, "GET", path, socket.host_uri.host || "localhost") do
      %{route: route, path_params: path_params} ->
        {:ok, route, path_params}

      _ ->
        :error
    end
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
      route_pattern = LSocket.get(socket, :route_pattern)
      path_param_names = LSocket.get(socket, :path_param_names) || MapSet.new()
      url_field_names = url_fields |> Enum.map(& &1.name) |> MapSet.new()

      # Separate path params from query params
      {path_fields, query_fields} =
        Enum.split_with(url_fields, fn field ->
          MapSet.member?(path_param_names, field.name)
        end)

      # Build the path by substituting path params into the route pattern
      # First, substitute fields that are defined in the DSL
      path =
        Enum.reduce(path_fields, route_pattern, fn field, pattern ->
          value = Map.get(state, field.name)

          encoded =
            if field.encode do
              field.encode.(value)
            else
              Type.dump(field.type, value)
            end

          # Replace :param_name with the actual value
          String.replace(pattern, ":#{field.name}", to_string(encoded))
        end)

      # Now substitute any remaining path params that aren't in the DSL
      # (e.g., product_id in /products/:product_id/counter when using a counter LiveView)
      # These values were stored from the route info during handle_params
      path_param_values = LSocket.get(socket, :path_param_values) || %{}
      path =
        Enum.reduce(path_param_names, path, fn param_name, pattern ->
          if MapSet.member?(url_field_names, param_name) do
            # Already handled above
            pattern
          else
            # Get from stored path param values
            value = Map.get(path_param_values, param_name)
            if value do
              String.replace(pattern, ":#{param_name}", to_string(value))
            else
              pattern
            end
          end
        end)

      # Build query params from non-path fields
      query_params =
        Enum.reduce(query_fields, %{}, fn field, acc ->
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
        if query_params == %{} do
          path
        else
          path <> "?" <> URI.encode_query(query_params)
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
