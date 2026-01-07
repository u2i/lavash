defmodule Lavash.Component.Runtime do
  @moduledoc """
  Runtime implementation for Lavash Components.

  Handles:
  - Props from parent
  - Internal socket/ephemeral state
  - Read/form DSL (like LiveView)
  - Derived state computation
  - Action execution (including submit, notify_parent)
  - Assign projection
  """

  alias Lavash.Rx.Graph
  alias Lavash.Assigns
  alias Lavash.State
  alias Lavash.Socket, as: LSocket
  alias Lavash.Action.Runtime, as: ActionRuntime
  alias Lavash.Form.Runtime, as: FormRuntime

  def update(module, assigns, socket) do
    # Check if this is an invoke from parent
    case Map.get(assigns, :__lavash_invoke__) do
      {action_name, params} ->
        # Handle invoke - execute the action
        handle_invoke(module, action_name, params, socket)

      nil ->
        # Check if this is an invalidation from parent LiveView
        case Map.get(assigns, :__lavash_invalidate__) do
          resource when is_atom(resource) and not is_nil(resource) ->
            # Handle resource invalidation - same logic as LiveView
            handle_invalidate(module, resource, socket)

          nil ->
            # Check if this is an async result delivery
            case Map.get(assigns, :__lavash_async_result__) do
              {field, result} ->
                # Handle async result delivery - convert to AsyncResult struct
                async =
                  case result do
                    {:ok, value} ->
                      Phoenix.LiveView.AsyncResult.ok(value)

                    {:error, reason} ->
                      Phoenix.LiveView.AsyncResult.failed(%Phoenix.LiveView.AsyncResult{}, reason)

                    value ->
                      Phoenix.LiveView.AsyncResult.ok(value)
                  end

                socket =
                  socket
                  |> LSocket.put_derived(field, async)
                  |> Graph.recompute_dependents(module, field)
                  |> Assigns.project(module)

                {:ok, socket}

              nil ->
                # Normal update
                socket =
                  if first_mount?(socket) do
                    # First mount - initialize everything
                    # Register with parent for invalidation forwarding
                    register_with_parent(module, assigns)

                    socket
                    |> init_lavash_state(module, assigns)
                    |> hydrate_socket_state(module, assigns)
                    |> hydrate_ephemeral(module)
                    |> State.hydrate_forms(module)
                    |> store_props(module, assigns)
                    |> preserve_livecomponent_assigns(module, assigns)
                    |> Graph.recompute_all(module)
                    |> Assigns.project(module)
                  else
                    # Subsequent update - store props (marks changed props as dirty)
                    socket = store_props(socket, module, assigns)
                    socket = preserve_livecomponent_assigns(socket, module, assigns)

                    # Recompute any derived fields affected by dirty props
                    socket =
                      if LSocket.dirty?(socket) do
                        Graph.recompute_dirty(socket, module)
                      else
                        socket
                      end

                    Assigns.project(socket, module)
                  end

                {:ok, socket}
            end
        end
    end
  end

  defp handle_invalidate(module, resource, socket) do
    # Invalidate all reads/derives that depend on this resource
    fields_to_invalidate = Graph.fields_for_resource(module, resource)

    if fields_to_invalidate != [] do
      # Mark these fields as dirty and recompute
      socket =
        socket
        |> LSocket.mark_dirty(fields_to_invalidate)
        |> Graph.recompute_dirty(module)
        |> Assigns.project(module)

      {:ok, socket}
    else
      {:ok, socket}
    end
  end

  defp handle_invoke(module, action_name, params, socket) do
    actions = module.__lavash__(:actions)

    case Enum.find(actions, &(&1.name == action_name)) do
      nil ->
        require Logger
        Logger.warning("Lavash invoke: action #{action_name} not found in #{inspect(module)}")
        {:ok, socket}

      action ->
        case execute_action(socket, module, action, params) do
          {:ok, socket, notify_events} ->
            socket =
              socket
              |> maybe_sync_socket_state(module)
              |> Graph.recompute_dirty(module)
              |> Assigns.project(module)
              |> apply_notify_parents(notify_events)

            {:ok, socket}

          {:error, socket, on_error_action} ->
            # Action failed with on_error - trigger the error action
            actions = module.__lavash__(:actions)
            error_action = Enum.find(actions, &(&1.name == on_error_action))

            socket =
              if error_action do
                case execute_action(socket, module, error_action, params) do
                  {:ok, sock, _notify} -> sock
                  {:error, sock, _} -> sock
                end
              else
                socket
              end

            socket =
              socket
              |> maybe_sync_socket_state(module)
              |> Graph.recompute_dirty(module)
              |> Assigns.project(module)

            {:ok, socket}
        end
    end
  end

  def handle_event(module, event, params, socket) do
    # First, check for form bindings and update state if params match
    socket = apply_form_bindings(socket, module, params)

    # Look up by string comparison to avoid atom creation DoS
    actions = module.__lavash__(:actions)

    case Enum.find(actions, &(Atom.to_string(&1.name) == event)) do
      nil ->
        # No matching action - but form bindings may have updated state
        if LSocket.dirty?(socket) do
          socket =
            socket
            |> Graph.recompute_dirty(module)
            |> Assigns.project(module)

          {:noreply, socket}
        else
          {:noreply, socket}
        end

      action ->
        case execute_action(socket, module, action, params) do
          {:ok, socket, notify_events} ->
            socket =
              socket
              |> maybe_sync_socket_state(module)
              |> Graph.recompute_dirty(module)
              |> Assigns.project(module)
              |> apply_notify_parents(notify_events)

            # Return reply so pushEventTo callbacks are triggered
            {:reply, %{}, socket}

          {:error, socket, on_error_action} ->
            # Action failed with on_error - trigger the error action
            actions = module.__lavash__(:actions)
            error_action = Enum.find(actions, &(&1.name == on_error_action))

            socket =
              if error_action do
                case execute_action(socket, module, error_action, params) do
                  {:ok, sock, _notify} -> sock
                  {:error, sock, _} -> sock
                end
              else
                socket
              end

            socket =
              socket
              |> maybe_sync_socket_state(module)
              |> Graph.recompute_dirty(module)
              |> Assigns.project(module)

            # Return reply so pushEventTo callbacks are triggered
            {:reply, %{}, socket}
        end
    end
  end

  # Private

  defp first_mount?(socket) do
    socket.private[:lavash] == nil
  end

  defp register_with_parent(module, assigns) do
    # Collect resources this component uses (from reads and forms)
    reads = module.__lavash__(:reads)
    forms = module.__lavash__(:forms)

    resources =
      (Enum.map(reads, & &1.resource) ++ Enum.map(forms, & &1.resource))
      |> Enum.uniq()

    # Only register if we have resources to watch
    if resources != [] do
      component_id = Map.get(assigns, :id, "unknown")
      # Send registration message to parent LiveView
      send(self(), {:lavash_register_component, component_id, module, resources})
    end
  end

  defp init_lavash_state(socket, module, assigns) do
    socket_field_names =
      module.__lavash__(:socket_fields)
      |> Enum.map(& &1.name)
      |> MapSet.new()

    # Component ID for namespacing socket state
    component_id = Map.get(assigns, :id, "unknown")

    LSocket.init(socket, %{
      socket_fields: socket_field_names,
      component_id: component_id
    })
  end

  defp hydrate_socket_state(socket, module, assigns) do
    socket_fields = module.__lavash__(:socket_fields)

    # Get initial state from parent via __lavash_initial_state__ prop
    # This is populated by the parent LiveView from connect_params
    client_state = Map.get(assigns, :__lavash_initial_state__, %{})

    state =
      Enum.reduce(socket_fields, LSocket.state(socket), fn field, state ->
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

    LSocket.put(socket, :state, state)
  end

  defp preserve_livecomponent_assigns(socket, module, assigns) do
    # Preserve LiveComponent built-in assigns and store the module for async callbacks
    # Note: :myself is reserved and auto-assigned by LiveView, so we don't set it
    socket
    |> Phoenix.Component.assign(:id, Map.get(assigns, :id))
    |> Phoenix.Component.assign(:__component_module__, module)
  end

  defp hydrate_ephemeral(socket, module) do
    ephemeral_fields = module.__lavash__(:ephemeral_fields)

    state =
      Enum.reduce(ephemeral_fields, LSocket.state(socket), fn field, state ->
        if Map.has_key?(state, field.name) do
          state
        else
          Map.put(state, field.name, field.default)
        end
      end)

    LSocket.put(socket, :state, state)
  end

  defp store_props(socket, module, assigns) do
    props = module.__lavash__(:props)
    old_props = LSocket.get(socket, :props) || %{}

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

    # Mark changed props as dirty so derived fields get recomputed
    socket =
      Enum.reduce(prop_values, socket, fn {name, new_value}, sock ->
        old_value = Map.get(old_props, name)

        if old_value != new_value do
          LSocket.update(sock, :dirty, &MapSet.put(&1, name))
        else
          sock
        end
      end)

    # Store props separately and also merge into state for derived field access
    socket
    |> LSocket.put(:props, prop_values)
    |> update_state_with_props(prop_values)
  end

  defp update_state_with_props(socket, prop_values) do
    # Merge props into state so derived fields can depend on them
    state = Map.merge(LSocket.state(socket), prop_values)
    LSocket.put(socket, :state, state)
  end

  defp apply_form_bindings(socket, module, params) do
    forms = module.__lavash__(:forms)

    Enum.reduce(forms, socket, fn form, sock ->
      params_field = :"#{form.name}_params"
      # Use the form name as the params namespace (e.g., "form" for :form input)
      param_key = to_string(form.name)

      case Map.get(params, param_key) do
        nil ->
          sock

        form_params when is_map(form_params) ->
          LSocket.put_state(sock, params_field, form_params)

        _ ->
          sock
      end
    end)
  end

  defp execute_action(socket, module, action, event_params) do
    params = ActionRuntime.build_params(action.params, event_params)

    if ActionRuntime.guards_pass?(socket, module, action.when) do
      socket =
        socket
        |> ActionRuntime.apply_sets(action.sets || [], params, module)
        |> ActionRuntime.apply_updates(action.updates || [], params)
        |> ActionRuntime.apply_effects(action.effects || [], params)

      # Collect notify_parent events to execute after state updates
      notify_events = collect_notify_events(socket, module, action.notify_parents || [])

      # Handle submits - these can fail and trigger on_error
      apply_submits(socket, module, action.submits || [], notify_events)
    else
      {:ok, socket, []}
    end
  end

  defp collect_notify_events(socket, _module, notify_parents) do
    props = LSocket.get(socket, :props) || %{}

    Enum.map(notify_parents, fn notify ->
      # The event can be a prop name (atom) that references the event name stored in props,
      # or a literal string event name
      case notify.event do
        name when is_binary(name) ->
          # Literal string event name
          name

        prop_name when is_atom(prop_name) ->
          # Reference to a prop that holds the event name
          Map.get(props, prop_name)
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp apply_notify_parents(socket, []) do
    socket
  end

  defp apply_notify_parents(socket, [event | rest]) do
    # Send event to parent LiveView by sending a message to self()
    # Since the LiveComponent runs in the same process as the parent LiveView,
    # this will be handled by the parent's handle_info callback
    send(self(), {:lavash_component_event, event, %{}})

    apply_notify_parents(socket, rest)
  end

  defp apply_submits(socket, _module, [], notify_events) do
    {:ok, socket, notify_events}
  end

  defp apply_submits(socket, module, [submit | rest], notify_events) do
    # Recompute derived state to get the latest form
    socket = Graph.recompute_dirty(socket, module)

    # Get the form from derived state
    raw_form = LSocket.derived(socket)[submit.field]

    # Handle the form value - it might be wrapped in AsyncResult from async operations
    form =
      case raw_form do
        %Phoenix.LiveView.AsyncResult{ok?: true, result: f} -> f
        %Phoenix.LiveView.AsyncResult{loading: loading} when loading != nil -> :loading
        f -> f
      end

    # Extract resource from form for mutation signaling
    resource = FormRuntime.extract_resource(form)

    # Use Lavash.Form.submit which handles Lavash.Form, Ash.Changeset,
    # AshPhoenix.Form, and Phoenix.HTML.Form
    result = Lavash.Form.submit(form)

    case result do
      {:ok, _result} ->
        # Success - trigger on_success action FIRST (may close modal, etc.)
        socket =
          if submit.on_success do
            actions = module.__lavash__(:actions)
            success_action = Enum.find(actions, &(&1.name == submit.on_success))

            if success_action do
              case execute_action(socket, module, success_action, %{}) do
                {:ok, sock, more_notify} ->
                  # Accumulate notify events from success action
                  apply_notify_parents(sock, more_notify)

                {:error, sock, _err} ->
                  sock
              end
            else
              socket
            end
          else
            socket
          end

        # Broadcast resource mutation for cross-process invalidation
        if resource do
          # Broadcast to all relevant combination topics based on changed attributes
          FormRuntime.broadcast_mutation(form)
        end

        apply_submits(socket, module, rest, notify_events)

      {:error, :loading} ->
        # Form is still loading - this shouldn't happen if UI is correct
        # but handle gracefully by triggering on_error
        if submit.on_error do
          {:error, socket, submit.on_error}
        else
          {:ok, socket, notify_events}
        end

      {:error, _form_with_errors} ->
        # Failure - trigger on_error action if specified
        if submit.on_error do
          {:error, socket, submit.on_error}
        else
          # No on_error handler, just return ok with current socket
          {:ok, socket, notify_events}
        end
    end
  end

  defp maybe_sync_socket_state(socket, module) do
    if LSocket.socket_changed?(socket) do
      socket_fields = module.__lavash__(:socket_fields)
      state = LSocket.state(socket)
      component_id = LSocket.get(socket, :component_id)

      socket_state =
        Enum.reduce(socket_fields, %{}, fn field, acc ->
          value = Map.get(state, field.name)
          Map.put(acc, to_string(field.name), value)
        end)

      # Push component state to JS, namespaced by component ID
      socket
      |> LSocket.clear_socket_changed()
      |> Phoenix.LiveView.push_event("_lavash_component_sync", %{
        id: component_id,
        state: socket_state
      })
    else
      socket
    end
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
