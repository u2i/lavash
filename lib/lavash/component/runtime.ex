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
    # Check if this is a binding update from a child component
    case Map.get(assigns, :__lavash_binding_update__) do
      {action, field, value} ->
        # Handle binding update from child ClientComponent or Lavash.Component
        handle_binding_update(module, action, field, value, socket)

      nil ->
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
                        |> resolve_bindings(assigns)
                        |> preserve_livecomponent_assigns(module, assigns)
                        |> Graph.recompute_all(module)
                        |> Assigns.project(module)
                      else
                        # Subsequent update - store props (marks changed props as dirty)
                        socket = store_props(socket, module, assigns)
                        socket = resolve_bindings(socket, assigns)
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

  defp handle_binding_update(module, action, field, value, socket) do
    # Handle binding update from a child component
    # The child has modified a bound field and is notifying us

    # Parse the value if it's a string representation
    parsed_value = parse_binding_value(value)

    # Update our state with the new value
    socket =
      socket
      |> LSocket.bump_optimistic_version()
      |> LSocket.put_state(field, parsed_value)
      |> Graph.recompute_dirty(module)
      |> Assigns.project(module)

    # Check if this field is bound upward to our parent
    # If so, propagate the update (for nested binding chains)
    binding_map = socket.assigns[:__lavash_binding_map__] || %{}

    case Map.get(binding_map, field) do
      nil ->
        # Not bound upward - we're the owner, send to LiveView
        send(self(), {action, field, parsed_value})

      parent_field ->
        # Bound upward - propagate to our parent
        case socket.assigns[:__lavash_parent_cid__] do
          nil ->
            # No parent CID - send to LiveView
            send(self(), {action, parent_field, parsed_value})

          parent_cid ->
            # Parent is a Lavash.Component - use send_update
            Phoenix.LiveView.send_update(parent_cid, __lavash_binding_update__: {action, parent_field, parsed_value})
        end
    end

    {:ok, socket}
  end

  defp parse_binding_value("true"), do: true
  defp parse_binding_value("false"), do: false
  defp parse_binding_value(nil), do: nil
  defp parse_binding_value(%{key: key, arg: arg}), do: %{key: key, arg: arg}
  defp parse_binding_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ ->
        case Float.parse(value) do
          {float, ""} -> float
          _ -> value
        end
    end
  end
  defp parse_binding_value(value), do: value

  # Resolve bindings from the bind prop - sets up binding map and parent CID
  defp resolve_bindings(socket, assigns) do
    case Map.get(assigns, :bind) do
      nil ->
        # Even without bindings, ensure __lavash_client_bindings__ exists for child components
        # This is needed because the TokenTransformer injects assigns.__lavash_client_bindings__
        # into all child component calls within templates compiled with context: :component
        Phoenix.Component.assign(socket, :__lavash_client_bindings__, %{})

      bindings when is_list(bindings) ->
        # Build a map of local_name -> parent_field
        binding_map =
          Enum.into(bindings, %{}, fn {local, parent} ->
            {local, parent}
          end)

        # Store the binding map for later use in handle_binding_update
        socket = Phoenix.Component.assign(socket, :__lavash_binding_map__, binding_map)

        # Store client bindings (resolved/flattened) for JS lavash-set events
        # If __lavash_client_bindings__ was passed, use it; otherwise use binding_map
        # This is critical for nested component chains - child bindings resolve
        # through parent bindings to reach the root LiveView field name
        client_bindings = Map.get(assigns, :__lavash_client_bindings__) || binding_map
        socket = Phoenix.Component.assign(socket, :__lavash_client_bindings__, client_bindings)

        # Store parent CID for routing bound field updates via send_update
        # This is passed when the child is rendered inside a Lavash.Component
        socket =
          case Map.get(assigns, :__lavash_parent_cid__) do
            nil -> socket
            parent_cid -> Phoenix.Component.assign(socket, :__lavash_parent_cid__, parent_cid)
          end

        # Sync parent's optimistic version when bound
        socket =
          case Map.get(assigns, :__lavash_parent_version__) do
            nil -> socket
            parent_version -> Phoenix.Component.assign(socket, :__lavash_version__, parent_version)
          end

        # For each binding, look up the parent's current value and update our state
        Enum.reduce(bindings, socket, fn {local, _parent}, sock ->
          value = Map.get(assigns, local)
          # Update both the assign and the internal state
          sock
          |> Phoenix.Component.assign(local, value)
          |> LSocket.put_state(local, value)
        end)
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
    socket =
      socket
      |> Phoenix.Component.assign(:id, Map.get(assigns, :id))
      |> Phoenix.Component.assign(:__component_module__, module)

    # Preserve current_user for actor-based authorization in read DSL and form submits
    # This is inherited from the parent via lavash_component helper
    case Map.get(assigns, :current_user) do
      nil -> socket
      user -> Phoenix.Component.assign(socket, :current_user, user)
    end
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
      server_errors_field = :"#{form.name}_server_errors"
      # Use the form name as the params namespace (e.g., "form" for :form input)
      param_key = to_string(form.name)

      case Map.get(params, param_key) do
        nil ->
          sock

        form_params when is_map(form_params) ->
          sock
          |> LSocket.put_state(params_field, form_params)
          |> LSocket.put_state(server_errors_field, %{})

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
        |> ActionRuntime.apply_runs(action.runs || [], params, module)
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

    # Get actor from socket assigns for authorization
    actor = socket.assigns[:current_user]

    # Use Lavash.Form.submit which handles Lavash.Form, Ash.Changeset,
    # AshPhoenix.Form, and Phoenix.HTML.Form
    result = Lavash.Form.submit(form, actor: actor)

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

      {:error, form_with_errors} ->
        # Extract per-field errors from the submit failure and store in server_errors
        server_errors = extract_submit_errors(form_with_errors)
        server_errors_field = :"#{submit.field}_server_errors"

        socket =
          socket
          |> LSocket.put_state(server_errors_field, server_errors)
          |> Graph.recompute_dirty(module)
          |> Assigns.project(module)

        # Failure - trigger on_error action if specified
        if submit.on_error do
          {:error, socket, submit.on_error}
        else
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

  # Extract per-field errors from Ash submit failure for storage in server_errors state.
  # Returns a map of %{"field_name" => ["error message", ...]}
  defp extract_submit_errors(%Ash.Error.Invalid{errors: errors}) do
    Enum.reduce(errors, %{}, fn error, acc ->
      case error do
        %{field: field, message: msg} when not is_nil(field) ->
          field_str = to_string(field)
          message = case msg do
            {m, _opts} -> m
            m when is_binary(m) -> m
            _ -> "Invalid value"
          end
          Map.update(acc, field_str, [message], &[message | &1])

        _ ->
          acc
      end
    end)
  end

  defp extract_submit_errors(_), do: %{}
end
