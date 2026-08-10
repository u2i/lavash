defmodule Lavash.Action.Runtime do
  @moduledoc """
  Shared action execution runtime for both LiveView and Component.

  This module contains the common logic for executing actions:
  - `guards_pass?/3` - Check if action guards are satisfied
  - `apply_sets/4` - Apply set operations to state
  - `apply_runs/4` - Apply run operations (fn assigns -> assigns end)
  - `apply_effects/3` - Execute side effect functions
  - `coerce_value/2` - Coerce values to declared types

  Runtime-specific operations (invoke, navigate, flash) remain
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
  Executes an action's `mutate`/`remove`/`append` ops (the durable
  Ash writes + broadcast) and marks their backing reads dirty, so
  the cascade re-reads them in this event. The diff the client
  receives then carries post-write truth — confirming the client's
  prediction instead of pushing a stale list.
  """
  def apply_client_state_mutations(socket, action, params, module) do
    socket = Lavash.ClientState.apply_mutations(socket, action, params, module)

    case Lavash.ClientState.reads_to_refresh(module, action) do
      [] -> socket
      reads -> LSocket.mark_dirty(socket, reads)
    end
  end

  @doc """
  Apply set operations to state.

  Each set has a field and a value. The value can be:
  - A literal value
  - An rx() struct (reactive expression with @field syntax)
  - A function that receives `%{params: params, state: state}` (server-only escape hatch)

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
  Apply pre-cascade run operations. Each body takes a socket and
  returns a socket; the body runs BEFORE the reactive cascade.

  The runtime sweeps `socket.assigns.__changed__` after the body
  returns and threads any not-yet-dirty fields through
  `LSocket.put_state/3` so the cascade sees them. This means
  pre-cascade bodies can use either `Lavash.Socket.put_state/3`
  (explicit) or `Phoenix.Component.assign/3` (raw) and both end
  up in lavash's dirty set.

  Event params are merged into `socket.assigns` for the body's
  duration so `socket.assigns.body`, `.id`, etc. resolve from
  `phx-value-*` payloads — matches the contract `apply_runs/5`
  uses for post-cascade bodies.
  """
  def apply_pre_runs(socket, action_name, pre_runs, params, module) do
    (pre_runs || [])
    |> Enum.with_index()
    |> Enum.reduce(socket, fn {_pre_run, idx}, sock ->
      assigns_with_params =
        sock.assigns
        |> Map.merge(params)
        |> Map.put(:__changed__, %{})

      sock_with_params = %{sock | assigns: assigns_with_params}

      # The body was hoisted at compile time into a generated function on
      # the user's module (see `CompileLiveView.build_run_refs_ast/1` and
      # the equivalent for components). Calling it via apply/3 means local
      # helpers, aliases, and imports inside the user's module resolve
      # normally — no `:erl_eval` involved.
      new_sock = apply(module, :__lavash_pre_run__, [action_name, idx, sock_with_params])

      # Sweep __changed__ to catch raw `assign/3` writes that didn't
      # go through `put_state` (which would have marked dirty itself).
      changed = Map.get(new_sock.assigns, :__changed__, %{})
      already_dirty = LSocket.dirty(new_sock)

      Enum.reduce(changed, new_sock, fn {field, _marker}, acc ->
        if MapSet.member?(already_dirty, field) do
          acc
        else
          LSocket.put_state(acc, field, Map.get(new_sock.assigns, field))
        end
      end)
    end)
  end

  @doc """
  Apply post-cascade run operations. Each body takes a socket and
  returns a socket; the returned socket replaces the current one.

  Runs AFTER the reactive cascade has settled. The body sees
  consistent calc values and can do socket-level LV ops
  (`stream_insert/4`, `allow_upload/3`,
  `consume_uploaded_entries/3`, `cancel_upload/3`) that don't fit
  the declarative state-mutation shape.

  Writes the body makes to `socket.assigns` (via `put_state`,
  `assign/3`, or LV ops) land for Phoenix's render diff but do
  NOT trigger a re-cascade. Calcs depending on what `run` wrote
  are stale until the next user event. If you need a derived
  value of a write, use `pre_run` instead.
  """
  def apply_runs(socket, action_name, runs, params, module) do
    (runs || [])
    |> Enum.with_index()
    |> Enum.reduce(socket, fn {_run, idx}, sock ->
      assigns_with_params = Map.merge(sock.assigns, params)
      sock_with_params = %{sock | assigns: assigns_with_params}

      apply(module, :__lavash_run__, [action_name, idx, sock_with_params])
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
