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

  alias Lavash.Action.Runtime, as: ActionRuntime
  alias Lavash.Assigns
  alias Lavash.Dsl.Graph, as: DslGraph
  alias Lavash.Form.Runtime, as: FormRuntime
  alias Lavash.Reactive
  alias Lavash.Socket, as: LSocket
  alias Lavash.State

  def update(module, assigns, socket) do
    cond do
      match?({:lavash_field_op, _, _, _}, Map.get(assigns, :__lavash_binding_update__)) ->
        {:lavash_field_op, op, field, value} = assigns.__lavash_binding_update__
        handle_binding_update(module, op, field, value, socket)

      match?({_, _}, Map.get(assigns, :__lavash_invoke__)) ->
        {action_name, params} = assigns.__lavash_invoke__
        handle_invoke(module, action_name, params, socket)

      is_atom(Map.get(assigns, :__lavash_invalidate__)) and
          not is_nil(Map.get(assigns, :__lavash_invalidate__)) ->
        handle_invalidate(module, assigns.__lavash_invalidate__, socket)

      match?({_, _}, Map.get(assigns, :__lavash_async_result__)) ->
        {field, result} = assigns.__lavash_async_result__
        handle_async_result(module, field, result, socket)

      true ->
        handle_normal_update(module, assigns, socket)
    end
  end

  defp handle_async_result(module, field, result, socket) do
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
      |> Reactive.recompute_dependents(field)
      |> Assigns.project(module)

    {:ok, socket}
  end

  defp handle_normal_update(module, assigns, socket) do
    socket =
      if first_mount?(socket) do
        register_with_parent(module, assigns)

        socket
        |> init_lavash_state(module, assigns)
        |> hydrate_socket_state(module, assigns)
        |> hydrate_ephemeral(module, assigns)
        |> State.hydrate_forms(module)
        |> store_props(module, assigns)
        |> resolve_bindings(module, assigns)
        |> preserve_livecomponent_assigns(module, assigns)
        |> Reactive.recompute_all()
        |> Assigns.project(module)
      else
        socket
        |> hydrate_ephemeral(module, assigns)
        |> store_props(module, assigns)
        |> resolve_bindings(module, assigns)
        |> preserve_livecomponent_assigns(module, assigns)
        |> maybe_recompute()
        |> Assigns.project(module)
      end

    {:ok, socket}
  end

  defp maybe_recompute(socket) do
    if LSocket.dirty?(socket), do: Reactive.recompute(socket), else: socket
  end

  defp handle_invalidate(module, resource, socket) do
    # Invalidate all reads/derives that depend on this resource
    fields_to_invalidate = DslGraph.fields_for_resource(module, resource)

    if fields_to_invalidate != [] do
      # Mark these fields as dirty and recompute
      socket =
        socket
        |> LSocket.mark_dirty(fields_to_invalidate)
        |> Reactive.recompute()
        |> Assigns.project(module)

      {:ok, socket}
    else
      {:ok, socket}
    end
  end

  defp handle_binding_update(module, op, field, value, socket) do
    # Handle binding update from a child component
    # The child has modified a bound field and is notifying us

    # Parse the value if it's a string representation
    parsed_value = Lavash.Type.decode_wire(value)

    # Update our state with the new value
    socket =
      socket
      |> Lavash.Optimistic.Version.bump()
      |> LSocket.put_state(field, parsed_value)
      |> Reactive.recompute()
      |> Assigns.project(module)

    # Check if this field is bound upward to our parent
    # If so, propagate the update (for nested binding chains)
    binding_map = socket.assigns[:__lavash_binding_map__] || %{}

    case Map.get(binding_map, field) do
      nil ->
        # Not bound upward - we're the owner, send to LiveView
        send(self(), {:lavash_field_op, op, field, parsed_value})

      parent_field ->
        # Bound upward - propagate to our parent
        case socket.assigns[:__lavash_parent_cid__] do
          nil ->
            # No parent CID - send to LiveView
            send(self(), {:lavash_field_op, op, parent_field, parsed_value})

          parent_cid ->
            # Parent is a Lavash.Component - use send_update
            Phoenix.LiveView.send_update(parent_cid,
              __lavash_binding_update__: {:lavash_field_op, op, parent_field, parsed_value}
            )
        end
    end

    {:ok, socket}
  end

  # Resolve bindings from the bind prop - sets up binding map and parent CID
  defp resolve_bindings(socket, module, assigns) do
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
            nil ->
              socket

            parent_version ->
              Phoenix.Component.assign(socket, :__lavash_version__, parent_version)
          end

        # For bound fields, we need to update state when the prop changes from parent,
        # but preserve child's local modifications when the prop hasn't changed.
        # Bound fields are not declared props, so we track their previous values separately.
        old_bound_props = LSocket.get(socket, :bound_props) || %{}

        # Get modal open field if this component uses the modal DSL
        modal_open_field = get_modal_open_field(module)

        {socket, new_bound_props} =
          Enum.reduce(bindings, {socket, %{}}, fn {local, _parent}, {sock, bound_acc} ->
            new_value = Map.get(assigns, local)
            old_value = Map.get(old_bound_props, local)
            state = LSocket.state(sock)
            state_value = Map.get(state, local)

            # Track this value for next update
            bound_acc = Map.put(bound_acc, local, new_value)

            # Only update state if the prop actually changed from parent
            # This preserves child's local modifications (e.g., on_saved setting open: nil)
            sock =
              if old_value != new_value do
                # Prop changed from parent - update state
                sock =
                  sock
                  |> Phoenix.Component.assign(local, new_value)
                  |> LSocket.put_state(local, new_value)

                # If this is the modal open field transitioning from closed to open,
                # clear form params so we don't show stale data from previous session
                if local == modal_open_field and is_nil(old_value) and not is_nil(new_value) do
                  clear_form_params_on_modal_open(sock, module)
                else
                  sock
                end
              else
                # Prop didn't change - preserve existing state value
                Phoenix.Component.assign(sock, local, state_value)
              end

            {sock, bound_acc}
          end)

        # Store bound prop values for next update
        LSocket.put(socket, :bound_props, new_bound_props)
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
        # Capture bound field state before action execution for change detection
        binding_map = socket.assigns[:__lavash_binding_map__] || %{}
        bound_state_before = capture_bound_field_state(socket, binding_map)

        case execute_action(socket, module, action, params) do
          {:ok, socket} ->
            socket =
              socket
              |> maybe_sync_socket_state(module)
              |> Assigns.project(module)
              |> propagate_bound_field_changes(binding_map, bound_state_before)

            {:ok, socket}

          {:error, socket, on_error_action} ->
            # Action failed with on_error - trigger the error action
            actions = module.__lavash__(:actions)
            error_action = Enum.find(actions, &(&1.name == on_error_action))

            socket =
              if error_action do
                case execute_action(socket, module, error_action, params) do
                  {:ok, sock} -> sock
                  {:error, sock, _} -> sock
                end
              else
                socket
              end

            socket =
              socket
              |> maybe_sync_socket_state(module)
              |> Assigns.project(module)
              |> propagate_bound_field_changes(binding_map, bound_state_before)

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
            |> Reactive.recompute()
            |> Assigns.project(module)

          {:noreply, socket}
        else
          {:noreply, socket}
        end

      action ->
        # Capture bound field state before action execution for change detection
        binding_map = socket.assigns[:__lavash_binding_map__] || %{}
        bound_state_before = capture_bound_field_state(socket, binding_map)

        case execute_action(socket, module, action, params) do
          {:ok, socket} ->
            socket =
              socket
              |> maybe_sync_socket_state(module)
              |> Assigns.project(module)
              |> propagate_bound_field_changes(binding_map, bound_state_before)

            # Return reply so pushEventTo callbacks are triggered
            {:reply, %{}, socket}

          {:error, socket, on_error_action} ->
            # Action failed with on_error - trigger the error action
            actions = module.__lavash__(:actions)
            error_action = Enum.find(actions, &(&1.name == on_error_action))

            socket =
              if error_action do
                case execute_action(socket, module, error_action, params) do
                  {:ok, sock} -> sock
                  {:error, sock, _} -> sock
                end
              else
                socket
              end

            socket =
              socket
              |> maybe_sync_socket_state(module)
              |> Assigns.project(module)
              |> propagate_bound_field_changes(binding_map, bound_state_before)

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
      component_id: component_id,
      graph: DslGraph.compiled_graph(module)
    })
  end

  defp hydrate_socket_state(socket, module, assigns) do
    socket_fields = module.__lavash__(:socket_fields)
    client_state = Map.get(assigns, :__lavash_initial_state__, %{})

    Enum.reduce(socket_fields, socket, fn field, sock ->
      key = to_string(field.name)
      raw_value = Map.get(client_state, key)

      value =
        cond do
          not Map.has_key?(client_state, key) -> field.default
          is_nil(raw_value) -> field.default
          raw_value == "" and field.type != :string -> field.default
          true -> decode_type(raw_value, field.type)
        end

      LSocket.put_state(sock, field.name, value)
    end)
  end

  defp preserve_livecomponent_assigns(socket, module, assigns) do
    # Preserve LiveComponent built-in assigns and store the module for async callbacks
    # Note: :myself is reserved and auto-assigned by LiveView, so we don't set it
    socket =
      socket
      |> Phoenix.Component.assign(:id, Map.get(assigns, :id))
      |> Phoenix.Component.assign(:__component_module__, module)
      |> Phoenix.Component.assign(
        :__lavash_component_states__,
        Map.get(assigns, :__lavash_component_states__) || %{}
      )

    # Preserve current_user for actor-based authorization in read DSL and form submits
    # This is inherited from the parent via lavash_component helper
    case Map.get(assigns, :current_user) do
      nil -> socket
      user -> Phoenix.Component.assign(socket, :current_user, user)
    end
  end

  defp hydrate_ephemeral(socket, module, assigns) do
    ephemeral_fields = module.__lavash__(:ephemeral_fields)
    current_state = LSocket.state(socket)

    Enum.reduce(ephemeral_fields, socket, fn field, sock ->
      cond do
        # Parent explicitly passed this field as an assign — use it
        Map.has_key?(assigns, field.name) ->
          LSocket.put_state(sock, field.name, Map.get(assigns, field.name))

        # Already in state (from a previous update) — keep it
        Map.has_key?(current_state, field.name) ->
          sock

        # Not in state yet, no parent value — use default
        true ->
          LSocket.put_state(sock, field.name, field.default)
      end
    end)
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
    # Pass old_props BEFORE storing new ones so we can detect changes
    socket
    |> update_state_with_props(prop_values, old_props)
    |> LSocket.put(:props, prop_values)
  end

  defp update_state_with_props(socket, prop_values, old_props) do
    # Merge props into state so derived fields can depend on them
    # For props that are also state fields (bound props), only update state
    # when the prop changed from parent - otherwise preserve state value
    # so child's local modifications aren't overwritten
    current_state = LSocket.state(socket)

    Enum.reduce(prop_values, socket, fn {name, new_value}, sock ->
      old_value = Map.get(old_props, name)

      if old_value != new_value do
        # Prop changed from parent, always update state
        LSocket.put_state(sock, name, new_value)
      else
        # Prop didn't change - keep existing state value if present
        if Map.has_key?(current_state, name) do
          sock
        else
          # State doesn't have this field yet, initialize from prop
          LSocket.put_state(sock, name, new_value)
        end
      end
    end)
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
    append_ids = ActionRuntime.parse_append_ids(event_params)

    if ActionRuntime.guards_pass?(socket, module, action.when) do
      socket
      # Pre-cascade: state mutations
      |> ActionRuntime.apply_sets(action.sets || [], params, module)
      |> ActionRuntime.apply_pre_runs(action.name, action.pre_runs || [], params, module)
      # mutate/remove/append: Ash writes + broadcast, then the backing
      # reads re-read post-write in this cascade
      |> ActionRuntime.apply_client_state_mutations(action, params, module, append_ids)
      # Cascade settles all calcs once
      |> Reactive.recompute()
      # Post-cascade: socket-level ops + side effects
      |> ActionRuntime.apply_runs(action.name, action.runs || [], params, module)
      |> ActionRuntime.apply_effects(action.effects || [], params)
      |> apply_submits(module, action.submits || [])
    else
      {:ok, socket}
    end
  end

  defp apply_submits(socket, _module, []) do
    {:ok, socket}
  end

  defp apply_submits(socket, module, [submit | rest]) do
    # Recompute derived state to get the latest form
    socket = Reactive.recompute(socket)

    # Get the form from assigns (raw Lavash.Form or AsyncResult)
    raw_form = socket.assigns[submit.field]

    # Handle the form value - it might be wrapped in AsyncResult from async operations
    form =
      case raw_form do
        %Phoenix.LiveView.AsyncResult{ok?: true, result: f} -> f
        %Phoenix.LiveView.AsyncResult{loading: loading} when loading != nil -> :loading
        f -> f
      end

    # Extract resource from form for mutation signaling
    resource = FormRuntime.extract_resource(form)

    # Resolve the Ash actor for this submit. Prefers an explicit
    # `:actor` prop, falls back to `:current_user`. See
    # `Lavash.Form.Runtime.resolve_actor/1`.
    actor = FormRuntime.resolve_actor(socket)

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
                {:ok, sock} -> sock
                {:error, sock, _err} -> sock
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

        apply_submits(socket, module, rest)

      {:error, :loading} ->
        # Form is still loading - this shouldn't happen if UI is correct
        # but handle gracefully by triggering on_error
        if submit.on_error do
          {:error, socket, submit.on_error}
        else
          {:ok, socket}
        end

      {:error, form_with_errors} ->
        # Extract per-field errors from the submit failure and store in server_errors
        server_errors = FormRuntime.extract_submit_errors(form_with_errors)
        server_errors_field = :"#{submit.field}_server_errors"

        socket =
          socket
          |> LSocket.put_state(server_errors_field, server_errors)
          |> Reactive.recompute()
          |> Assigns.project(module)

        # Failure - trigger on_error action if specified
        if submit.on_error do
          {:error, socket, submit.on_error}
        else
          {:ok, socket}
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

  # Capture bound field state before action execution for change detection
  defp capture_bound_field_state(socket, binding_map) do
    state = LSocket.state(socket)

    Enum.into(binding_map, %{}, fn {local_field, _parent_field} ->
      {local_field, Map.get(state, local_field)}
    end)
  end

  # Propagate bound field changes to parent after action execution
  defp propagate_bound_field_changes(socket, binding_map, bound_state_before) do
    state = LSocket.state(socket)

    Enum.each(binding_map, fn {local_field, parent_field} ->
      old_value = Map.get(bound_state_before, local_field)
      new_value = Map.get(state, local_field)

      if old_value != new_value do
        # Propagate to parent using same mechanism as handle_binding_update
        case socket.assigns[:__lavash_parent_cid__] do
          nil ->
            # Parent is LiveView - send message directly
            send(self(), {:lavash_field_op, :set, parent_field, new_value})

          parent_cid ->
            # Parent is another Lavash.Component - use send_update
            Phoenix.LiveView.send_update(parent_cid,
              __lavash_binding_update__: {:lavash_field_op, :set, parent_field, new_value}
            )
        end
      end
    end)

    socket
  end

  # Get the modal open field from module metadata, if this component uses modal DSL
  defp get_modal_open_field(module) do
    Spark.Dsl.Extension.get_persisted(module, :modal_open_field)
  rescue
    _ -> nil
  end

  # Clear all form params and mark reads as dirty when modal opens to prevent stale data
  defp clear_form_params_on_modal_open(socket, module) do
    forms = module.__lavash__(:forms)
    reads = module.__lavash__(:reads)

    # Clear form params and server errors
    socket =
      Enum.reduce(forms, socket, fn form, sock ->
        params_field = :"#{form.name}_params"
        server_errors_field = :"#{form.name}_server_errors"

        sock
        |> LSocket.put_state(params_field, %{})
        |> LSocket.put_state(server_errors_field, %{})
      end)

    # Mark reads as dirty so they re-fetch with the new open value
    # This triggers recompute_dirty to run the async reads again
    read_names = Enum.map(reads, & &1.name)
    LSocket.mark_dirty(socket, read_names)
  end
end
