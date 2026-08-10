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

  require Logger
  require Phoenix.Component

  alias Lavash.Action.Runtime, as: ActionRuntime
  alias Lavash.Assigns
  alias Lavash.Dsl.Graph, as: DslGraph
  alias Lavash.Form.Runtime, as: FormRuntime
  alias Lavash.Reactive
  alias Lavash.Socket, as: LSocket
  alias Lavash.State

  @doc """
  Layer-1 entry point that wraps the user's render output if the
  optimism extension is loaded. Delegates to
  `Lavash.Optimistic.RenderWrapper.wrap_render/3` when that module
  exists; otherwise returns `inner_content` unchanged.

  The optimism wrapper produces a
  `<div phx-hook="LavashOptimistic" data-lavash-state=...>` shell
  around the user's content. A layer-2-only build that omits the
  `Lavash.Optimistic.RenderWrapper` module gets no wrapper, no
  hook, and no embedded JSON state — pure server-authoritative
  rendering. See `docs/ARCHITECTURE.md` punchlist item #8.

  ## Why `Code.ensure_loaded?` vs `function_exported?`

  `function_exported?/3` returns false for modules that haven't
  been loaded yet, even if they'd be loadable on demand. Phoenix
  LiveView renders run after the module compile cycle, so the
  optimism module is reachable but may not be loaded into the BEAM
  in the rare case it was tree-shaken. `Code.ensure_loaded?/1`
  forces the load attempt and then `function_exported?` confirms
  the symbol exists.
  """
  def wrap_render(module, assigns, inner_content) do
    wrapper = Lavash.Optimistic.RenderWrapper

    if Code.ensure_loaded?(wrapper) and function_exported?(wrapper, :wrap_render, 3) do
      wrapper.wrap_render(module, assigns, inner_content)
    else
      inner_content
    end
  end

  def mount(module, _params, session, socket) do
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
        component_states: component_states,
        graph: DslGraph.compiled_graph(module)
      })
      |> Phoenix.Component.assign(:__lavash_component_states__, component_states)
      |> State.hydrate_socket(module, connect_params)
      |> State.hydrate_session(module, session || %{})
      |> State.hydrate_assigns(module)
      |> State.hydrate_ephemeral(module)
      |> State.hydrate_forms(module)

    # Run the user's `mount do ... end` lifecycle block (async-field
    # init + op-sequence). Pulled in here rather than at the top-level
    # generated mount/3 so a user-overridden mount (escape hatch for
    # temporary_assigns: and similar) still benefits from the block.
    socket =
      if function_exported?(module, :__lavash_mount_lifecycle__, 1) do
        module.__lavash_mount_lifecycle__(socket)
      else
        socket
      end

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
      |> Reactive.recompute_all()
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
        handle_validation_event(module, socket, form, form_name, params)

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
  # Also handles form recovery when phx-change fires with full form params
  defp handle_validation_event(module, socket, form, form_name, params) do
    # Check if this is a per-field validation (Lavash client-side) or full form change (Phoenix recovery)
    field_name = params["field"]
    param_key = to_string(form_name)

    cond do
      # Per-field validation from Lavash client
      field_name != nil ->
        handle_per_field_validation(module, socket, form, form_name, params)

      # Full form change (e.g., from Phoenix form recovery)
      Map.has_key?(params, param_key) ->
        handle_form_change(module, socket, form_name, params[param_key])

      true ->
        {:noreply, socket}
    end
  end

  # Handle Phoenix form change events (form recovery, standard phx-change)
  defp handle_form_change(module, socket, form_name, form_params) when is_map(form_params) do
    params_field = :"#{form_name}_params"
    server_errors_field = :"#{form_name}_server_errors"

    socket =
      socket
      |> LSocket.put_state(params_field, form_params)
      |> LSocket.put_state(server_errors_field, %{})
      |> Reactive.recompute()
      |> Assigns.project(module)

    {:noreply, socket}
  end

  defp handle_form_change(_module, socket, _form_name, _), do: {:noreply, socket}

  # Handle per-field validation from Lavash client
  # Server validates the field and stores errors in #{form}_server_errors state.
  # The _errors derive merges these with client-computed errors.
  # Result flows to client via normal re-render → data-lavash-server-errors attribute.
  defp handle_per_field_validation(module, socket, form, form_name, params) do
    field_name = params["field"]
    value = params["value"]

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
            %{field: ^field} ->
              true

            %{field: field_atom} when is_atom(field_atom) ->
              to_string(field_atom) == to_string(field)

            _ ->
              false
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

    # Store errors in server_errors state → triggers _errors derive recomputation → re-render
    server_errors_field = :"#{form_name}_server_errors"
    current_errors = LSocket.get_state(socket, server_errors_field) || %{}
    updated_errors = Map.put(current_errors, field_name, errors)

    socket =
      socket
      |> LSocket.put_state(server_errors_field, updated_errors)
      |> Reactive.recompute()
      |> Assigns.project(module)

    {:noreply, socket}
  end

  defp handle_action_event(module, event, params, socket) do
    # Capture old state for subscription updates
    old_state = LSocket.state(socket)

    # First, check for form bindings and update state if params match
    socket = apply_form_bindings(socket, module, params)

    # Check for set_{field} events from child component binding propagation
    # When a child component sets a bound field, it propagates via lavash-set event
    # which the JS hook converts to a set_{field} server event
    case parse_set_field_event(module, event) do
      {:set, field_name} ->
        # Update the state field with the provided value
        value = params["value"]
        socket = LSocket.put_state(socket, field_name, value)

        socket =
          socket
          |> Lavash.Optimistic.Version.bump()
          |> Reactive.recompute()
          |> Assigns.project(module)

        update_combination_subscriptions(socket, module, old_state)
        {:noreply, socket}

      :not_set_field ->
        # Then try to find and execute a matching action
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

              update_combination_subscriptions(socket, module, old_state)
              {:noreply, socket}
            else
              {:noreply, socket}
            end

          action ->
            # Bump optimistic version - client will use this to detect stale patches
            socket = Lavash.Optimistic.Version.bump(socket)

            case execute_action(socket, module, action, params) do
              {:ok, socket} ->
                # execute_action has already settled the cascade.
                # Now emit LV-level side effects against the
                # post-cascade view.
                socket =
                  socket
                  |> apply_flashes(action.flashes || [])
                  |> apply_navigates(action.navigates || [])
                  |> apply_push_patches(action.push_patches || [])
                  |> apply_redirects(action.redirects || [])
                  |> apply_push_events(action.push_events || [], module, params)
                  |> maybe_push_patch(module)
                  |> maybe_sync_socket_state(module)
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
                  |> Assigns.project(module)

                update_combination_subscriptions(socket, module, old_state)
                {:noreply, socket}
            end
        end
    end
  end

  # Check if event is a set_{field} event for a valid ephemeral state field
  # Returns {:set, field_atom} if valid, :not_set_field otherwise
  defp parse_set_field_event(module, event) do
    case event do
      "set_" <> field_str ->
        # Get all ephemeral state fields that can be set via binding propagation
        ephemeral_fields = module.__lavash__(:ephemeral_fields)
        field_names = Enum.map(ephemeral_fields, & &1.name)

        # Only accept if this is a known state field AND there's no explicit
        # user-defined action with this name. User actions take priority over
        # auto-generated setters because they may transform the value (e.g.,
        # String.to_integer).
        field_atom = String.to_existing_atom(field_str)

        if field_atom in field_names do
          # Check if a user-defined action with this name exists
          actions = module.__lavash__(:actions)
          has_explicit_action = Enum.any?(actions, &(Atom.to_string(&1.name) == event))

          if has_explicit_action do
            :not_set_field
          else
            {:set, field_atom}
          end
        else
          :not_set_field
        end

      _ ->
        :not_set_field
    end
  rescue
    ArgumentError ->
      # String.to_existing_atom raised - atom doesn't exist
      :not_set_field
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

  def handle_info(module, {:lavash_reactive, field, {:ok, result}}, socket) do
    socket =
      socket
      |> LSocket.put_derived(field, Phoenix.LiveView.AsyncResult.ok(result))
      |> Reactive.recompute_dependents(field)
      |> Assigns.project(module)

    {:noreply, socket}
  end

  def handle_info(module, {:lavash_reactive, field, {:error, reason}}, socket) do
    failed =
      Phoenix.LiveView.AsyncResult.loading()
      |> Phoenix.LiveView.AsyncResult.failed({:exit, reason})

    socket =
      socket
      |> LSocket.put_derived(field, failed)
      |> Reactive.recompute_dependents(field)
      |> Assigns.project(module)

    {:noreply, socket}
  end

  # Field operations from child Lavash components. The op atom selects how
  # `value` is applied to the named field. Adding a new op means one extra
  # `apply_field_op/4` clause and an extra atom in the guard — no new
  # top-level handle_info clause.
  def handle_info(module, {:lavash_field_op, op, field, value}, socket)
      when op in [:set] do
    socket =
      socket
      |> Lavash.Optimistic.Version.bump()
      |> apply_field_op(op, field, value)
      |> maybe_push_patch(module)
      |> Reactive.recompute()
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

  # Unrecognized :lavash_* tuples are library bugs — surface them.
  def handle_info(module, {tag, _, _} = msg, socket) when is_atom(tag) do
    if tag |> Atom.to_string() |> String.starts_with?("lavash_") do
      Logger.warning("Unhandled Lavash internal message in #{inspect(module)}: #{inspect(msg)}")
    end

    {:noreply, socket}
  end

  def handle_info(_module, _msg, socket) do
    {:noreply, socket}
  end

  defp apply_field_op(socket, :set, field, value) do
    LSocket.put_state(socket, field, Lavash.Type.decode_wire(value))
  end

  defp invalidate_resource(module, resource, socket) do
    # Invalidate all reads/derives that depend on this resource
    fields_to_invalidate = DslGraph.fields_for_resource(module, resource)

    socket =
      if fields_to_invalidate != [] do
        # Mark these fields as dirty and recompute
        socket
        |> LSocket.update(:dirty, fn dirty ->
          Enum.reduce(fields_to_invalidate, dirty, &MapSet.put(&2, &1))
        end)
        |> Reactive.recompute()
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
    params = ActionRuntime.build_params(action.params, event_params)

    # Check guards
    if ActionRuntime.guards_pass?(socket, module, action.when) do
      socket =
        socket
        # Pre-cascade: state mutations
        |> ActionRuntime.apply_sets(action.sets || [], params, module)
        |> ActionRuntime.apply_pre_runs(action.name, action.pre_runs || [], params, module)
        # mutate/remove/append: Ash writes + broadcast, then the backing
        # reads re-read post-write in this cascade
        |> ActionRuntime.apply_client_state_mutations(action, params, module)
        # Cascade settles all calcs once
        |> Reactive.recompute()
        # Post-cascade: socket-level ops + side effects (see settled state)
        |> ActionRuntime.apply_runs(action.name, action.runs || [], params, module)
        |> ActionRuntime.apply_effects(action.effects || [], params)
        |> apply_invokes(action.invokes || [], params)

      # Handle submits. Validation failures come back as {:error, form_with_errors}
      # from Lavash.Form.submit and are routed to on_error inside apply_submits.
      # Other exceptions are bugs and should crash the LiveView per Phoenix
      # conventions — silent rescue here previously hid them behind a flash
      # while also bypassing on_error.
      apply_submits(socket, module, action.submits || [])
    else
      {:ok, socket}
    end
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
      |> Reactive.recompute()

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
    # `:actor` assign, falls back to `:current_user`. See
    # `Lavash.Form.Runtime.resolve_actor/1`.
    actor = FormRuntime.resolve_actor(socket)

    # Use Lavash.Form.submit which handles Lavash.Form, Ash.Changeset,
    # AshPhoenix.Form, and Phoenix.HTML.Form
    result = Lavash.Form.submit(form, actor: actor)

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

  defp apply_push_patches(socket, []), do: socket

  defp apply_push_patches(socket, [patch | _rest]) do
    # Same one-per-action rule as navigate.
    Phoenix.LiveView.push_patch(socket, to: patch.to)
  end

  defp apply_redirects(socket, []), do: socket

  defp apply_redirects(socket, [redir | _rest]) do
    Phoenix.LiveView.redirect(socket, to: redir.to)
  end

  defp apply_push_events(socket, [], _module, _params), do: socket

  defp apply_push_events(socket, events, module, params) do
    # Resolve rx() values in the payload against the action's effective
    # state at fire time. Literal values pass through unchanged.
    state = Map.merge(LSocket.full_state(socket), params)

    Enum.reduce(events, socket, fn event, sock ->
      resolved_payload = resolve_push_event_payload(event.payload, module, state)
      Phoenix.LiveView.push_event(sock, event.name, resolved_payload)
    end)
  end

  defp resolve_push_event_payload(%Lavash.Rx{} = rx, module, state) do
    Lavash.Rx.Cache.compile_rx(module, rx.ast).(state)
  end

  defp resolve_push_event_payload(map, module, state) when is_map(map) do
    Map.new(map, fn {k, v} ->
      {k, resolve_push_event_payload(v, module, state)}
    end)
  end

  defp resolve_push_event_payload(list, module, state) when is_list(list) do
    Enum.map(list, &resolve_push_event_payload(&1, module, state))
  end

  defp resolve_push_event_payload(other, _module, _state), do: other

  defp maybe_push_patch(socket, _module) do
    # URL sync is now handled client-side via history.replaceState in the
    # LavashOptimistic hook. This avoids triggering a live_patch which would
    # interrupt inflight events (causing rapid clicks to be dropped).
    # Just clear the URL changed flag.
    LSocket.clear_url_changed(socket)
  end

  defp maybe_sync_socket_state(socket, module) do
    if LSocket.socket_changed?(socket) do
      socket_fields = module.__lavash__(:socket_fields)
      state = LSocket.state(socket)

      # Build the socket state map to send to client
      socket_state =
        Enum.reduce(socket_fields, %{}, fn field, acc ->
          value = Map.get(state, field.name)
          Map.put(acc, to_string(field.name), Lavash.Type.dump(field.type, value))
        end)

      require Logger
      Logger.debug("[Lavash] syncing socket state to client: #{inspect(socket_state)}")

      socket
      |> LSocket.clear_socket_changed()
      |> Phoenix.LiveView.push_event("_lavash_sync", socket_state)
    else
      socket
    end
  end
end
