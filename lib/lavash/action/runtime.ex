defmodule Lavash.Action.Runtime do
  @moduledoc """
  Shared action execution runtime for both LiveView and Component.

  This module contains the common logic for executing actions:
  - `guards_pass?/3` - Check if action guards are satisfied
  - `apply_sets/4` - Apply set operations to state
  - `apply_updates/3` - Apply update operations to state
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
  - A function that receives `%{params: params, state: state}`

  Values are coerced to the field's declared type.
  """
  def apply_sets(socket, sets, params, module) do
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
      Map.put(acc, param, Map.get(event_params, key))
    end)
  end
end
