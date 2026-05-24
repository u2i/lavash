defmodule Lavash.Action.Runtime do
  @moduledoc """
  Shared action execution runtime for both LiveView and Component.

  This module contains the common logic for executing actions:
  - `guards_pass?/3` - Check if action guards are satisfied
  - `apply_sets/4` - Apply set operations to state
  - `apply_runs/4` - Apply run operations (fn assigns -> assigns end)
  - `apply_updates/3` - Apply update operations to state (deprecated)
  - `apply_effects/3` - Execute side effect functions
  - `coerce_value/2` - Coerce values to declared types

  Runtime-specific operations (invoke, notify_parent, navigate, flash) remain
  in their respective runtime modules.
  """

  alias Lavash.Socket, as: LSocket
  alias Lavash.Type

  @doc """
  Check if all guard conditions pass.

  Guards are atoms referencing derived boolean fields that must all be true.
  """
  def guards_pass?(socket, _module, guards) do
    state = LSocket.full_state(socket)
    Enum.all?(guards, fn guard -> Map.get(state, guard) == true end)
  end

  @doc """
  Apply set operations to state.

  Each set has a field and a value. The value can be:
  - A literal value
  - An rx() struct (reactive expression with @field syntax)
  - A function that receives `%{params: params, state: state}` (legacy)

  Values are coerced to the field's declared type.
  """
  def apply_sets(socket, sets, params, module) do
    states = module.__lavash__(:states)

    Enum.reduce(sets, socket, fn set, sock ->
      value = evaluate_set_value(set.value, sock, params, module)

      # Coerce value to the field's declared type
      state_field = Enum.find(states, &(&1.name == set.field))
      coerced = coerce_value(value, state_field)

      LSocket.put_state(sock, set.field, coerced)
    end)
  end

  # Evaluate a set value based on its type
  defp evaluate_set_value(%Lavash.Rx{ast: ast}, sock, params, module) do
    # Build state map from all lavash fields + params
    state =
      LSocket.full_state(sock)
      |> Map.merge(params)

    Lavash.Rx.Cache.compile_rx(module, ast).(state)
  end

  defp evaluate_set_value(fun, sock, params, _module) when is_function(fun, 1) do
    state = LSocket.full_state(sock)
    fun.(%{params: params, state: state})
  end

  defp evaluate_set_value(literal, _sock, _params, _module) do
    # Literal value
    literal
  end

  @doc """
  Apply run operations to state.

  Each run has a function (as quoted AST) that receives an assigns map (state + params merged)
  and returns updated assigns using Phoenix.Component.assign/3.

  This enables proper change tracking via the assigns mechanism.
  """
  def apply_runs(socket, runs, params, module) do
    Enum.reduce(runs || [], socket, fn run, sock ->
      state = LSocket.state(sock)
      assigns = Map.merge(state, params) |> Map.put(:__changed__, %{})

      fun = Lavash.Rx.Cache.compile_run_fun(module, run.fun)
      updated_assigns = fun.(assigns)

      # Extract changed fields and apply them to socket
      changed = Map.get(updated_assigns, :__changed__, %{})

      # Phoenix.Component.assign stores either `true` (initial render) or the
      # old value (subsequent change) under each changed key, so we accept
      # any value here.
      Enum.reduce(changed, sock, fn {field, _change_marker}, acc_sock ->
        value = Map.get(updated_assigns, field)
        LSocket.put_state(acc_sock, field, value)
      end)
    end)
  end

  @doc """
  Coerce a value to the declared type of a state field.

  Handles:
  - nil state field (no coercion)
  - nil values (pass through)
  - Empty strings for non-string types (convert to nil)
  - String values parsed via Type.parse/2
  """
  def coerce_value(value, nil), do: value
  def coerce_value(nil, _state_field), do: nil
  def coerce_value("", %{type: type}) when type != :string, do: nil

  def coerce_value(value, %{type: type}) when is_binary(value) do
    case Type.parse(type, value) do
      {:ok, parsed} -> parsed
      {:error, _} -> value
    end
  end

  def coerce_value(value, _state_field), do: value

  @doc """
  Apply update operations to state.

  Each update has a field and a function that transforms the current value.
  """
  def apply_updates(socket, updates, _params) do
    Enum.reduce(updates, socket, fn update, sock ->
      current = LSocket.get_state(sock, update.field)
      new_value = update.fun.(current)
      LSocket.put_state(sock, update.field, new_value)
    end)
  end

  @doc """
  Execute side effect functions.

  Each effect has a function that receives the current full state.
  Effects are executed for their side effects; the socket is returned unchanged.
  """
  def apply_effects(socket, effects, _params) do
    state = LSocket.full_state(socket)
    Enum.each(effects, fn effect -> effect.fun.(state) end)
    socket
  end

  @doc """
  Build params map from action params spec and event params.

  Extracts named parameters from the event payload.
  """
  def build_params(action_params, event_params) do
    Enum.reduce(action_params || [], %{}, fn param, acc ->
      key = to_string(param)

      value =
        case Map.get(event_params, key) do
          nil -> Map.get(event_params, "value")
          v -> v
        end

      Map.put(acc, param, value)
    end)
  end
end
