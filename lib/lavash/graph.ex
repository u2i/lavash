defmodule Lavash.Graph do
  @moduledoc """
  Dependency graph for derived state computation.

  Handles:
  - Topological sorting of derived fields
  - Dirty tracking and invalidation
  - Incremental recomputation
  - Async task management
  """

  def recompute_all(socket, module) do
    derived_fields = module.__lavash__(:derived_fields)
    sorted = topological_sort(derived_fields)

    Enum.reduce(sorted, socket, fn field, sock ->
      compute_field(sock, module, field)
    end)
  end

  def recompute_dirty(socket, module) do
    dirty = socket.assigns.__lavash_dirty__

    if MapSet.size(dirty) == 0 do
      socket
    else
      derived_fields = module.__lavash__(:derived_fields)

      # Find all derived fields affected by dirty state
      affected =
        derived_fields
        |> Enum.filter(fn field ->
          Enum.any?(field.depends_on, &MapSet.member?(dirty, &1))
        end)
        |> topological_sort()

      socket = Phoenix.Component.assign(socket, :__lavash_dirty__, MapSet.new())

      Enum.reduce(affected, socket, fn field, sock ->
        compute_field(sock, module, field)
      end)
    end
  end

  def recompute_dependents(socket, module, changed_field) do
    derived_fields = module.__lavash__(:derived_fields)

    dependents =
      derived_fields
      |> Enum.filter(fn field ->
        changed_field in field.depends_on
      end)
      |> topological_sort()

    Enum.reduce(dependents, socket, fn field, sock ->
      compute_field(sock, module, field)
    end)
  end

  defp compute_field(socket, _module, field) do
    deps = build_deps_map(socket, field.depends_on)

    # Check if any async deps are still loading
    if any_loading?(deps) do
      put_derived(socket, field.name, :loading)
    else
      if field.async do
        # Start async task
        self_pid = self()

        Task.start(fn ->
          result = field.compute.(deps)
          send(self_pid, {:lavash_async, field.name, result})
        end)

        put_derived(socket, field.name, :loading)
      else
        # Non-async: store raw result (no wrapping)
        result = field.compute.(deps)
        put_derived(socket, field.name, result)
      end
    end
  end

  defp build_deps_map(socket, deps) do
    state = socket.assigns.__lavash_state__
    derived = socket.assigns.__lavash_derived__

    Enum.reduce(deps, %{}, fn dep, acc ->
      value =
        cond do
          Map.has_key?(state, dep) -> Map.get(state, dep)
          # Pass derived values as-is (async: :loading/{:ok,_}/{:error,_}, sync: raw value)
          Map.has_key?(derived, dep) -> Map.get(derived, dep)
          true -> nil
        end

      Map.put(acc, dep, value)
    end)
  end

  defp any_loading?(deps) do
    Enum.any?(deps, fn {_k, v} -> v == :loading end)
  end

  defp put_derived(socket, field, value) do
    derived = socket.assigns.__lavash_derived__
    Phoenix.Component.assign(socket, :__lavash_derived__, Map.put(derived, field, value))
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
