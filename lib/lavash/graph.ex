defmodule Lavash.Graph do
  @moduledoc """
  Dependency graph for derived state computation.

  Handles:
  - Topological sorting of derived fields
  - Dirty tracking and invalidation
  - Incremental recomputation
  - Async task management
  - Automatic propagation of special states (:loading, :error, nil)
  """

  alias Lavash.Socket, as: LSocket
  alias Phoenix.LiveView.AsyncResult

  def recompute_all(socket, module) do
    all_fields = collect_all_fields(module)
    sorted = topological_sort(all_fields)

    Enum.reduce(sorted, socket, fn field, sock ->
      compute_field(sock, module, field)
    end)
  end

  # Collect all derived-like fields from different DSL sections
  defp collect_all_fields(module) do
    derived_fields = module.__lavash__(:derived_fields)
    read_fields = expand_reads(module)
    form_fields = expand_forms(module)
    derived_fields ++ read_fields ++ form_fields
  end

  # Expand read entities into derived-like field structs
  defp expand_reads(module) do
    reads = module.__lavash__(:reads)

    Enum.map(reads, fn read ->
      # Extract dependency from id option
      id_dep = extract_dependency(read.id)
      resource = read.resource
      action = read.action || :read
      is_async = read.async != false

      %Lavash.Derived.Field{
        name: read.name,
        depends_on: [id_dep],
        async: is_async,
        compute: fn deps ->
          id = Map.get(deps, id_dep)

          case id do
            nil -> nil
            id ->
              case Ash.get(resource, id, action: action) do
                {:ok, record} -> record
                {:error, %Ash.Error.Query.NotFound{}} -> nil
                {:error, error} -> raise error
              end
          end
        end
      }
    end)
  end

  # Expand form entities into derived-like field structs
  defp expand_forms(module) do
    forms = module.__lavash__(:forms)

    Enum.map(forms, fn form ->
      # Extract dependencies from data and params options
      data_dep = extract_dependency(form.data)

      # Params defaults to implicit :name_params if not specified
      params_dep =
        if form.params do
          extract_dependency(form.params)
        else
          :"#{form.name}_params"
        end

      depends_on =
        if data_dep do
          [data_dep, params_dep]
        else
          [params_dep]
        end

      resource = form.resource
      create_action = form.create || :create
      update_action = form.update || :update
      form_name = to_string(form.name)

      %Lavash.Derived.Field{
        name: form.name,
        depends_on: depends_on,
        async: false,
        compute: fn deps ->
          params = Map.get(deps, params_dep, %{})
          data = if data_dep, do: Map.get(deps, data_dep), else: nil

          Lavash.Form.for_resource(resource, data, params,
            create: create_action,
            update: update_action,
            as: form_name
          )
        end
      }
    end)
  end

  # Extract the field name from input(:x), result(:x), or prop(:x) tuples
  defp extract_dependency(source) do
    case source do
      {:input, name} -> name
      {:result, name} -> name
      {:prop, name} -> name
      name when is_atom(name) -> name
      nil -> nil
    end
  end

  def recompute_dirty(socket, module) do
    dirty = LSocket.dirty(socket)

    if MapSet.size(dirty) == 0 do
      socket
    else
      all_fields = collect_all_fields(module)

      # Find all derived fields affected by dirty state, including transitive dependencies
      # include_dirty: true means also include fields that are directly marked dirty
      affected = find_affected_derived(all_fields, dirty, include_dirty: true)
      sorted = topological_sort(affected)

      socket = LSocket.clear_dirty(socket)

      Enum.reduce(sorted, socket, fn field, sock ->
        compute_field(sock, module, field)
      end)
    end
  end

  defp find_affected_derived(derived_fields, dirty, opts \\ []) do
    include_dirty = Keyword.get(opts, :include_dirty, false)

    # Start with fields whose dependencies are dirty
    # Optionally also include fields that are directly marked dirty
    directly_affected =
      derived_fields
      |> Enum.filter(fn field ->
        deps_dirty = Enum.any?(field.depends_on, &MapSet.member?(dirty, &1))
        self_dirty = include_dirty and MapSet.member?(dirty, field.name)
        deps_dirty or self_dirty
      end)
      |> MapSet.new(& &1.name)

    # Transitively find all derived fields that depend on affected fields
    all_affected = expand_affected(directly_affected, derived_fields)

    # Return the actual field structs
    Enum.filter(derived_fields, fn f -> MapSet.member?(all_affected, f.name) end)
  end

  defp expand_affected(affected, all_fields) do
    # Find fields that depend on any affected field
    newly_affected =
      all_fields
      |> Enum.filter(fn field ->
        not MapSet.member?(affected, field.name) and
          Enum.any?(field.depends_on, &MapSet.member?(affected, &1))
      end)
      |> MapSet.new(& &1.name)

    if MapSet.size(newly_affected) == 0 do
      # No more fields to add
      affected
    else
      # Recurse with expanded set
      expand_affected(MapSet.union(affected, newly_affected), all_fields)
    end
  end

  def recompute_dependents(socket, module, changed_field) do
    all_fields = collect_all_fields(module)

    # Find all derived fields affected by the changed field, including transitive dependencies
    affected = find_affected_derived(all_fields, MapSet.new([changed_field]))
    sorted = topological_sort(affected)

    Enum.reduce(sorted, socket, fn field, sock ->
      compute_field(sock, module, field)
    end)
  end

  defp compute_field(socket, _module, field) do
    deps = build_deps_map(socket, field.depends_on)

    # Check for propagating states in dependencies
    case check_deps_state(deps) do
      {:propagate, state} ->
        # Propagate the special state without running compute
        LSocket.put_derived(socket, field.name, state)

      {:ready, had_async} ->
        # All deps are ready - run the compute function
        # had_async tells us if any dep was an AsyncResult (so we should wrap output)
        run_compute(socket, field, deps, had_async)
    end
  end

  defp check_deps_state(deps) do
    # Check for states that should propagate through the chain
    # Also track if any deps were AsyncResult (even if ok) so we can wrap output
    Enum.reduce_while(deps, {:ready, false}, fn {_key, value}, {_status, had_async} ->
      case value do
        %AsyncResult{loading: loading} when loading != nil ->
          {:halt, {:propagate, AsyncResult.loading()}}

        %AsyncResult{failed: failed} when failed != nil ->
          {:halt, {:propagate, value}}

        %AsyncResult{ok?: true} ->
          # Dep was async but is now ok - track this
          {:cont, {:ready, true}}

        _ ->
          {:cont, {:ready, had_async}}
      end
    end)
  end

  defp run_compute(socket, field, deps, had_async) do
    # Unwrap Async structs so compute functions receive plain values
    unwrapped_deps = unwrap_async_for_compute(deps)

    if field.async do
      # Start async task
      self_pid = self()

      # Check if we're in a component context (has component_id in lavash state)
      component_id = LSocket.get(socket, :component_id)

      if component_id do
        # For components, we need to use send_update to deliver async results
        # Get the component module from socket assigns
        component_module = socket.assigns[:__component_module__]

        Task.start(fn ->
          result = field.compute.(unwrapped_deps)
          # Send update to the component via the LiveView process
          send(self_pid, {:lavash_component_async, component_module, component_id, field.name, result})
        end)
      else
        # For LiveViews, use the standard approach
        Task.start(fn ->
          result = field.compute.(unwrapped_deps)
          send(self_pid, {:lavash_async, field.name, result})
        end)
      end

      LSocket.put_derived(socket, field.name, AsyncResult.loading())
    else
      # Non-async: store result, auto-wrapping changesets
      result = field.compute.(unwrapped_deps)
      wrapped = maybe_wrap_changeset(result)

      # If any dependency was async, wrap the result in AsyncResult.ok()
      # so downstream consumers (<.async_result>) can use it
      final =
        if had_async do
          AsyncResult.ok(wrapped)
        else
          wrapped
        end

      LSocket.put_derived(socket, field.name, final)
    end
  end

  # Auto-wrap Ash.Changeset to provide both form rendering and submission
  defp maybe_wrap_changeset(%Ash.Changeset{} = changeset) do
    Lavash.Form.wrap(changeset)
  end

  defp maybe_wrap_changeset(other), do: other

  defp build_deps_map(socket, deps) do
    state = LSocket.state(socket)
    derived = LSocket.derived(socket)

    Enum.reduce(deps, %{}, fn dep, acc ->
      value =
        cond do
          Map.has_key?(state, dep) ->
            Map.get(state, dep)

          Map.has_key?(derived, dep) ->
            # Pass through Async structs - check_deps_state will handle propagation
            # and unwrap_async_for_compute will extract the result when ready
            Map.get(derived, dep)

          true ->
            nil
        end

      Map.put(acc, dep, value)
    end)
  end

  # Unwrap Async structs for compute functions once check_deps_state returns :ready
  defp unwrap_async_for_compute(deps) do
    Map.new(deps, fn {key, value} ->
      unwrapped =
        case value do
          %AsyncResult{ok?: true, result: result} -> result
          other -> other
        end

      {key, unwrapped}
    end)
  end

  defp topological_sort(fields) do
    # Simple topological sort based on depends_on
    # For now, just sort by number of dependencies (crude but works for simple cases)
    Enum.sort_by(fields, fn field ->
      count_depth(field, fields, %{})
    end)
  end

  defp count_depth(field, all_fields, seen) do
    if Map.has_key?(seen, field.name) do
      0
    else
      deps = field.depends_on

      dep_depths =
        Enum.map(deps, fn dep ->
          case Enum.find(all_fields, &(&1.name == dep)) do
            nil -> 0
            dep_field -> 1 + count_depth(dep_field, all_fields, Map.put(seen, field.name, true))
          end
        end)

      case dep_depths do
        [] -> 0
        depths -> Enum.max(depths)
      end
    end
  end

  @doc """
  Returns field names that depend on reads/forms of a given resource.
  Used for resource-centric invalidation when a child component mutates a resource.
  """
  def fields_for_resource(module, resource) do
    # Get reads that use this resource
    read_fields =
      module.__lavash__(:reads)
      |> Enum.filter(&(&1.resource == resource))
      |> Enum.map(& &1.name)

    # Get forms that use this resource
    form_fields =
      module.__lavash__(:forms)
      |> Enum.filter(&(&1.resource == resource))
      |> Enum.map(& &1.name)

    # Get derived fields that declare this resource in their reads list
    derived_fields =
      module.__lavash__(:derived_fields)
      |> Enum.filter(fn field ->
        resource in (field.reads || [])
      end)
      |> Enum.map(& &1.name)

    read_fields ++ form_fields ++ derived_fields
  end
end
