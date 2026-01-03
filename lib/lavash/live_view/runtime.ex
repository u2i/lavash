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

  require Phoenix.Component

  alias Lavash.State
  alias Lavash.Graph
  alias Lavash.Assigns
  alias Lavash.Type
  alias Lavash.Socket, as: LSocket

  @doc """
  Wraps the user's render output with optimistic state tracking if needed.

  If the module has any optimistic fields (state or derives with `optimistic: true`),
  wraps the rendered content in a div with the LavashOptimistic hook and state data.
  """
  def wrap_render(module, assigns, inner_content) do
    optimistic_fields = module.__lavash__(:optimistic_fields)
    optimistic_derives = module.__lavash__(:optimistic_derives)

    if optimistic_fields == [] and optimistic_derives == [] do
      # No optimistic fields, just return the content directly
      inner_content
    else
      # Build optimistic state
      optimistic_state = Lavash.LiveView.Helpers.optimistic_state(module, assigns)
      module_name = inspect(module)
      optimistic_json = Jason.encode!(optimistic_state)

      # Get the optimistic version from socket (passed via assigns.__changed__ context)
      # We need to get it from the socket which is available in assigns
      version =
        case assigns do
          %{__changed__: _} = a ->
            # In a LiveView, we can access socket via assigns
            socket = Map.get(a, :socket)
            if socket, do: LSocket.optimistic_version(socket), else: 0

          _ ->
            0
        end

      # Optimistic functions are now extracted to colocated JS files at compile time
      # by Lavash.Optimistic.ColocatedTransformer, no need to embed them here
      has_optimistic_js = optimistic_fields != [] or optimistic_derives != []

      # Get URL field names for client-side URL sync
      url_field_names =
        module.__lavash__(:url_fields)
        |> Enum.map(& &1.name)

      # Escape for HTML attribute
      escaped_module = Phoenix.HTML.Safe.to_iodata(module_name)
      escaped_json = Phoenix.HTML.Safe.to_iodata(optimistic_json)
      escaped_url_fields = Phoenix.HTML.Safe.to_iodata(Jason.encode!(url_field_names))
      version_str = to_string(version)

      # Build wrapper as a Rendered struct so LiveView can diff it properly
      # The static parts are the wrapper div, dynamic parts include the inner content
      # Note: Optimistic functions are now loaded from colocated JS files (imported in app.js)
      # instead of being embedded as JSON and eval'd at runtime
      %Phoenix.LiveView.Rendered{
        static: [
          ~s(<div id="lavash-optimistic-root" phx-hook="LavashOptimistic" data-lavash-module="),
          ~s(" data-lavash-state="),
          ~s(" data-lavash-version="),
          ~s(" data-lavash-url-fields="),
          ~s(">),
          ~s(</div>)
        ],
        dynamic: fn _ ->
          [
            escaped_module,
            escaped_json,
            version_str,
            escaped_url_fields,
            inner_content
          ]
        end,
        # IMPORTANT: fingerprint must NOT include dynamic values (state, version) that change
        # on every update. Including them causes LiveView to treat this as a completely new
        # template, wiping out the component registry and breaking CID-based event targeting.
        # Only include structural information that defines the template shape.
        fingerprint: :erlang.phash2({module_name, url_field_names, has_optimistic_js}),
        root: true
      }
    end
  end

  def mount(module, _params, _session, socket) do
    # Get connect params if available (contains client-synced socket state)
    connect_params =
      if Phoenix.LiveView.connected?(socket) do
        Phoenix.LiveView.get_connect_params(socket) || %{}
      else
        %{}
      end

    # Subscribe to PubSub for resource invalidation (only when connected)
    if Phoenix.LiveView.connected?(socket) do
      subscribe_to_resources(module)
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
      |> State.hydrate_forms(module)

    {:ok, socket}
  end

  defp subscribe_to_resources(module) do
    # Subscribe to resource-level topics for all resources used in reads and forms
    # Attribute-level subscriptions are managed dynamically in update_attribute_subscriptions/3
    reads = module.__lavash__(:reads)
    forms = module.__lavash__(:forms)

    resources =
      (Enum.map(reads, & &1.resource) ++ Enum.map(forms, & &1.resource))
      |> Enum.uniq()

    Enum.each(resources, &Lavash.PubSub.subscribe/1)
  end

  @doc """
  Update combination-based subscriptions based on current filter values.

  For reads with `invalidate: :pubsub`, subscribes to a single combination topic
  based on which filters are currently active (non-nil). Uses the resource's
  `notify_on` configuration to determine which attributes to track.
  Unsubscribes from old topic when filter values change.
  """
  def update_combination_subscriptions(socket, module, old_state) do
    reads = module.__lavash__(:reads)
    state = LSocket.state(socket)

    # For each read with pubsub invalidation enabled
    Enum.each(reads, fn read ->
      if read.invalidate == :pubsub do
        resource = read.resource
        notify_attrs = Lavash.Resource.notify_on(resource)

        case notify_attrs do
          [] ->
            :ok

          attrs ->
            # Build filter values maps for old and new state
            old_filter_values = Map.take(old_state, attrs)
            new_filter_values = Map.take(state, attrs)

            # Only update if filter values changed
            if old_filter_values != new_filter_values do
              # Unsubscribe from old combination topic
              if old_state != %{} do
                Lavash.PubSub.unsubscribe_combination(resource, attrs, old_filter_values)
              end

              # Subscribe to new combination topic
              Lavash.PubSub.subscribe_combination(resource, attrs, new_filter_values)
            end
        end
      end
    end)

    socket
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

    # Capture old state for subscription updates
    old_state = LSocket.state(socket)

    socket =
      socket
      |> LSocket.put(:path, path)
      |> LSocket.put(:route_pattern, route_pattern)
      |> LSocket.put(:path_param_names, path_param_names)
      |> LSocket.put(:path_param_values, path_param_values)
      |> State.hydrate_url(module, params)
      |> Graph.recompute_all(module)
      |> Assigns.project(module)

    # Update combination-based subscriptions based on new filter values
    if Phoenix.LiveView.connected?(socket) do
      update_combination_subscriptions(socket, module, old_state)
    end

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
    # Check for form validation events (validate_<form_name>)
    case parse_validation_event(module, event) do
      {:validate, form, form_name} ->
        handle_validation_event(socket, form, form_name, params)

      :not_validation ->
        handle_action_event(module, event, params, socket)
    end
  end

  # Check if this is a validation event for one of our forms
  defp parse_validation_event(module, event) do
    forms = module.__lavash__(:forms)

    Enum.find_value(forms, :not_validation, fn form ->
      if event == "validate_#{form.name}" do
        {:validate, form, form.name}
      end
    end)
  end

  # Handle field validation request from client
  defp handle_validation_event(socket, form, form_name, params) do
    field_name = params["field"]
    value = params["value"]
    request_id = params["_validation_request_id"]

    # Convert field name to atom for Ash
    field = String.to_existing_atom(field_name)

    # Build a changeset to validate the field
    resource = form.resource

    # Get the action to use for validation (use form.create for create forms)
    action_name = form.create || :create

    # Get the domain from the resource
    domain =
      if function_exported?(resource, :spark_dsl_config, 0) do
        resource.spark_dsl_config()[:domain]
      else
        nil
      end

    # Build changeset with the field value
    params_map = %{to_string(field) => value}

    errors =
      try do
        changeset =
          resource
          |> Ash.Changeset.for_create(action_name, params_map, domain: domain)

        # Extract errors for this specific field
        changeset.errors
        |> Enum.filter(fn error ->
          case error do
            %{field: ^field} -> true
            %{field: field_atom} when is_atom(field_atom) ->
              to_string(field_atom) == to_string(field)
            _ -> false
          end
        end)
        |> Enum.map(fn error ->
          case error do
            %{message: msg} when is_binary(msg) -> msg
            %{message: {msg, _opts}} -> msg
            _ -> "Invalid value"
          end
        end)
      rescue
        _ -> []
      end

    # Push the validation result back to client
    socket =
      Phoenix.LiveView.push_event(socket, "validation_result", %{
        form: to_string(form_name),
        field: field_name,
        errors: errors,
        _validation_request_id: request_id
      })

    {:noreply, socket}
  end

  defp handle_action_event(module, event, params, socket) do
    # Capture old state for subscription updates
    old_state = LSocket.state(socket)

    # First, check for form bindings and update state if params match
    socket = apply_form_bindings(socket, module, params)

    # Then try to find and execute a matching action
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

          update_combination_subscriptions(socket, module, old_state)
          {:noreply, socket}
        else
          {:noreply, socket}
        end

      action ->
        # Bump optimistic version - client will use this to detect stale patches
        socket = LSocket.bump_optimistic_version(socket)

        case execute_action(socket, module, action, params) do
          {:ok, socket} ->
            socket =
              socket
              |> apply_flashes(action.flashes || [])
              |> apply_navigates(action.navigates || [])
              |> maybe_push_patch(module)
              |> maybe_sync_socket_state(module)
              |> Graph.recompute_dirty(module)
              |> Assigns.project(module)

            update_combination_subscriptions(socket, module, old_state)
            {:noreply, socket}

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
              |> maybe_push_patch(module)
              |> maybe_sync_socket_state(module)
              |> Graph.recompute_dirty(module)
              |> Assigns.project(module)

            update_combination_subscriptions(socket, module, old_state)
            {:noreply, socket}
        end
    end
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

  def handle_info(module, {:lavash_async, field, result}, socket) do
    # Convert result to AsyncResult struct
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

    {:noreply, socket}
  end

  def handle_info(module, {:lavash_component_event, event, params}, socket) do
    # Handle events sent from child Lavash components via notify_parent
    handle_event(module, event, params, socket)
  end

  def handle_info(module, {:lavash_component_delta, field, value}, socket) do
    # Handle state deltas from child Lavash components with bindings
    # This directly updates the parent's state and recomputes dependents
    socket =
      socket
      |> LSocket.put_state(field, value)
      |> maybe_push_patch(module)
      |> Graph.recompute_dirty(module)
      |> Assigns.project(module)

    {:noreply, socket}
  end

  def handle_info(module, {:lavash_component_toggle, field, value}, socket) do
    # Handle toggle operations from child Lavash components.
    # Components send atomic toggle ops (not full values) so rapid clicks
    # each apply to the current server state rather than overwriting each other.
    current = LSocket.get_state(socket, field) || []

    new_value =
      if value in current do
        List.delete(current, value)
      else
        [value | current]
      end

    require Logger
    Logger.warning("[Lavash] toggle #{field}: #{inspect(current)} + #{value} => #{inspect(new_value)}")

    socket =
      socket
      |> LSocket.bump_optimistic_version()
      |> LSocket.put_state(field, new_value)
      |> maybe_push_patch(module)
      |> Graph.recompute_dirty(module)
      |> Assigns.project(module)

    {:noreply, socket}
  end

  def handle_info(module, {:lavash_component_add, field, value}, socket) do
    # Handle add operations from child Lavash components.
    # Adds a value to an array field, with duplicate prevention.
    current = LSocket.get_state(socket, field) || []

    new_value =
      if value in current do
        current
      else
        current ++ [value]
      end

    socket =
      socket
      |> LSocket.bump_optimistic_version()
      |> LSocket.put_state(field, new_value)
      |> maybe_push_patch(module)
      |> Graph.recompute_dirty(module)
      |> Assigns.project(module)

    {:noreply, socket}
  end

  def handle_info(module, {:lavash_component_remove, field, value}, socket) do
    # Handle remove operations from child Lavash components.
    # Removes a value from an array field.
    current = LSocket.get_state(socket, field) || []
    new_value = Enum.reject(current, &(&1 == value))

    socket =
      socket
      |> LSocket.bump_optimistic_version()
      |> LSocket.put_state(field, new_value)
      |> maybe_push_patch(module)
      |> Graph.recompute_dirty(module)
      |> Assigns.project(module)

    {:noreply, socket}
  end

  def handle_info(
        _module,
        {:lavash_component_async, component_module, component_id, field, result},
        socket
      ) do
    # Handle async results for Lavash components
    # Use send_update to deliver the result to the component
    Phoenix.LiveView.send_update(self(), component_module, %{
      id: component_id,
      __lavash_async_result__: {field, result}
    })

    {:noreply, socket}
  end

  # Handle component registration for invalidation forwarding
  def handle_info(_module, {:lavash_register_component, id, component_module, resources}, socket) do
    # Subscribe to any new resources we're not already subscribed to
    Enum.each(resources, &Lavash.PubSub.subscribe/1)

    socket = LSocket.register_component(socket, id, component_module, resources)
    {:noreply, socket}
  end

  # Handle PubSub broadcast for resource invalidation
  # This is sent to both resource-level topics and combination topics
  def handle_info(module, {:lavash_invalidate, resource}, socket) do
    invalidate_resource(module, resource, socket)
  end

  def handle_info(_module, _msg, socket) do
    {:noreply, socket}
  end

  defp invalidate_resource(module, resource, socket) do
    # Invalidate all reads/derives that depend on this resource
    fields_to_invalidate = Graph.fields_for_resource(module, resource)

    socket =
      if fields_to_invalidate != [] do
        # Mark these fields as dirty and recompute
        socket
        |> LSocket.update(:dirty, fn dirty ->
          Enum.reduce(fields_to_invalidate, dirty, &MapSet.put(&2, &1))
        end)
        |> Graph.recompute_dirty(module)
        |> Assigns.project(module)
      else
        socket
      end

    # Forward invalidation to registered child components that care about this resource
    forward_invalidation_to_components(socket, resource)

    {:noreply, socket}
  end

  defp forward_invalidation_to_components(socket, resource) do
    registered = LSocket.registered_components(socket)

    Enum.each(registered, fn {id, {component_module, resources}} ->
      if resource in resources do
        Phoenix.LiveView.send_update(component_module, %{
          id: id,
          __lavash_invalidate__: resource
        })
      end
    end)
  end

  # Private

  defp execute_action(socket, module, action, event_params) do
    # Build params map from event
    params =
      Enum.reduce(action.params || [], %{}, fn param, acc ->
        key = to_string(param)
        Map.put(acc, param, Map.get(event_params, key))
      end)

    # Check guards
    if guards_pass?(socket, module, action.when) do
      socket =
        socket
        |> apply_sets(action.sets || [], params, module)
        |> apply_updates(action.updates || [], params)
        |> apply_effects(action.effects || [], params)
        |> apply_invokes(action.invokes || [], params)

      # Handle submits - these can fail and trigger on_error
      try do
        apply_submits(socket, module, action.submits || [])
      rescue
        e ->
          socket =
            Phoenix.LiveView.put_flash(
              socket,
              :error,
              "[DEBUG] Exception in submit: #{Exception.message(e)}"
            )

          {:ok, socket}
      end
    else
      {:ok, socket}
    end
  end

  defp guards_pass?(socket, _module, guards) do
    state = LSocket.full_state(socket)
    Enum.all?(guards, fn guard -> Map.get(state, guard) == true end)
  end

  defp apply_sets(socket, sets, params, module) do
    states = module.__lavash__(:states)

    Enum.reduce(sets, socket, fn set, sock ->
      value =
        case set.value do
          fun when is_function(fun, 1) ->
            fun.(%{params: params, state: LSocket.state(sock)})

          value ->
            value
        end

      # Coerce value to the field's declared type
      state_field = Enum.find(states, &(&1.name == set.field))
      coerced = coerce_value(value, state_field)

      LSocket.put_state(sock, set.field, coerced)
    end)
  end

  defp coerce_value(value, nil), do: value
  defp coerce_value(nil, _state_field), do: nil
  defp coerce_value("", %{type: type}) when type != :string, do: nil

  defp coerce_value(value, %{type: type}) when is_binary(value) do
    case Type.parse(type, value) do
      {:ok, parsed} -> parsed
      {:error, _} -> value
    end
  end

  defp coerce_value(value, _state_field), do: value

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

  defp apply_invokes(socket, invokes, params) do
    state = LSocket.state(socket)

    Enum.each(invokes, fn invoke ->
      # Build invoke params - values can be param(:x) references or literals
      invoke_params =
        Enum.reduce(invoke.params || [], %{}, fn {key, value}, acc ->
          resolved =
            case value do
              {:param, param_name} -> Map.get(params, param_name)
              {:state, field_name} -> Map.get(state, field_name)
              literal -> literal
            end

          Map.put(acc, to_string(key), resolved)
        end)

      component_id = to_string(invoke.target)
      component_module = invoke.module

      # Send the invoke via send_update
      Phoenix.LiveView.send_update(component_module, %{
        id: component_id,
        __lavash_invoke__: {invoke.action, invoke_params}
      })
    end)

    socket
  end

  defp apply_submits(socket, _module, []) do
    {:ok, socket}
  end

  defp apply_submits(socket, module, [submit | rest]) do
    # Recompute derived state to get the latest form
    socket =
      socket
      |> Graph.recompute_dirty(module)

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
    resource = extract_resource(form)

    # Use Lavash.Form.submit which handles Lavash.Form, Ash.Changeset,
    # AshPhoenix.Form, and Phoenix.HTML.Form
    result = Lavash.Form.submit(form)

    case result do
      {:ok, _result} ->
        # Success - trigger on_success action if specified, then continue with remaining submits
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
          # Broadcast to all relevant combination topics
          broadcast_mutation(module, form)
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

      {:error, _form_with_errors} ->
        # Failure - trigger on_error action if specified
        if submit.on_error do
          {:error, socket, submit.on_error}
        else
          # No on_error handler, just return ok with current socket
          {:ok, socket}
        end
    end
  end

  defp apply_flashes(socket, []) do
    socket
  end

  defp apply_flashes(socket, [flash | rest]) do
    socket
    |> Phoenix.LiveView.put_flash(flash.kind, flash.message)
    |> apply_flashes(rest)
  end

  defp apply_navigates(socket, []) do
    socket
  end

  defp apply_navigates(socket, [nav | _rest]) do
    # Only apply the first navigate (can't navigate twice)
    Phoenix.LiveView.push_navigate(socket, to: nav.to)
  end

  defp maybe_push_patch(socket, _module) do
    # URL sync is now handled client-side via history.replaceState in the
    # LavashOptimistic hook. This avoids triggering a live_patch which would
    # interrupt inflight events (causing rapid clicks to be dropped).
    # Just clear the URL changed flag.
    LSocket.clear_url_changed(socket)
  end

  defp _maybe_push_patch_server_side(socket, module) do
    # NOTE: This version uses push_patch which triggers handle_params and
    # interrupts inflight events. Use only if client-side URL sync is disabled.
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

  # Extract the Ash resource module from various form types
  defp extract_resource(%Lavash.Form{changeset: %Ash.Changeset{resource: resource}}), do: resource
  defp extract_resource(%Ash.Changeset{resource: resource}), do: resource
  defp extract_resource(%AshPhoenix.Form{resource: resource}), do: resource
  defp extract_resource(%Phoenix.HTML.Form{source: source}), do: extract_resource(source)
  defp extract_resource(_), do: nil

  # Broadcast mutation to all relevant combination topics
  # This enables fine-grained invalidation based on filter combinations
  defp broadcast_mutation(_module, form) do
    changeset = extract_changeset(form)

    if changeset do
      resource = changeset.resource
      old_record = changeset.data
      changed_attrs = changeset.attributes || %{}

      # Get notify_on attributes from the resource's Lavash extension
      notify_attrs = Lavash.Resource.notify_on(resource)

      if notify_attrs != [] do
        # Build changes map: %{attr => {old_value, new_value}}
        changes =
          notify_attrs
          |> Enum.filter(&Map.has_key?(changed_attrs, &1))
          |> Enum.map(fn attr ->
            old_value = if old_record, do: Map.get(old_record, attr), else: nil
            new_value = Map.get(changed_attrs, attr)
            {attr, {old_value, new_value}}
          end)
          |> Map.new()

        # Build unchanged map: %{attr => value} for notify attrs that didn't change
        unchanged =
          notify_attrs
          |> Enum.reject(&Map.has_key?(changed_attrs, &1))
          |> Enum.map(fn attr ->
            value = if old_record, do: Map.get(old_record, attr), else: nil
            {attr, value}
          end)
          |> Map.new()

        # Broadcast to all relevant combination topics
        Lavash.PubSub.broadcast_mutation(resource, notify_attrs, changes, unchanged)
      else
        # No fine-grained invalidation configured, just broadcast resource-level
        Lavash.PubSub.broadcast(resource)
      end
    else
      # Couldn't extract changeset, broadcast resource-level
      resource = extract_resource(form)
      if resource, do: Lavash.PubSub.broadcast(resource)
    end
  end

  defp extract_changeset(%Lavash.Form{changeset: changeset}), do: changeset
  defp extract_changeset(%Phoenix.HTML.Form{source: source}), do: extract_changeset(source)
  defp extract_changeset(%AshPhoenix.Form{source: %Ash.Changeset{} = cs}), do: cs
  defp extract_changeset(%Ash.Changeset{} = cs), do: cs
  defp extract_changeset(_), do: nil
end
