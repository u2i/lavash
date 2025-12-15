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

  def recompute_all(socket, module) do
    derived_fields = module.__lavash__(:derived_fields)
    sorted = topological_sort(derived_fields)

    Enum.reduce(sorted, socket, fn field, sock ->
      compute_field(sock, module, field)
    end)
  end

  def recompute_dirty(socket, module) do
    dirty = LSocket.dirty(socket)

    if MapSet.size(dirty) == 0 do
      socket
    else
      derived_fields = module.__lavash__(:derived_fields)

      # Find all derived fields affected by dirty state, including transitive dependencies
      # e.g., if :base is dirty and :doubled depends on :base, and :quadrupled depends on :doubled,
      # we need to recompute both :doubled and :quadrupled
      affected = find_affected_derived(derived_fields, dirty)
      sorted = topological_sort(affected)

      socket = LSocket.clear_dirty(socket)

      Enum.reduce(sorted, socket, fn field, sock ->
        compute_field(sock, module, field)
      end)
    end
  end

  defp find_affected_derived(derived_fields, dirty) do
    # Start with fields directly affected by dirty state
    directly_affected =
      derived_fields
      |> Enum.filter(fn field ->
        Enum.any?(field.depends_on, &MapSet.member?(dirty, &1))
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
    derived_fields = module.__lavash__(:derived_fields)

    # Find all derived fields affected by the changed field, including transitive dependencies
    affected = find_affected_derived(derived_fields, MapSet.new([changed_field]))
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

      :ready ->
        # All deps are ready - run the compute function
        run_compute(socket, field, deps)
    end
  end

  defp check_deps_state(deps) do
    # Check for states that should propagate through the chain
    Enum.reduce_while(deps, :ready, fn {_key, value}, _acc ->
      cond do
        value == :loading ->
          {:halt, {:propagate, :loading}}

        match?({:error, _}, value) ->
          {:halt, {:propagate, value}}

        true ->
          {:cont, :ready}
      end
    end)
  end

  defp run_compute(socket, field, deps) do
    if field.async do
      # Start async task
      self_pid = self()

      Task.start(fn ->
        result = field.compute.(deps)
        send(self_pid, {:lavash_async, field.name, result})
      end)

      LSocket.put_derived(socket, field.name, :loading)
    else
      # Non-async: store result, auto-wrapping changesets
      result = field.compute.(deps)
      wrapped = maybe_wrap_changeset(result)
      LSocket.put_derived(socket, field.name, wrapped)
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
            # Unwrap {:ok, value} from async results
            # But preserve :loading and {:error, _} for propagation checks
            case Map.get(derived, dep) do
              {:ok, v} -> v
              other -> other
            end

          true ->
            nil
        end

      Map.put(acc, dep, value)
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
end
