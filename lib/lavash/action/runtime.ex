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
      value = evaluate_set_value(set.value, sock, params)

      # Coerce value to the field's declared type
      state_field = Enum.find(states, &(&1.name == set.field))
      coerced = coerce_value(value, state_field)

      LSocket.put_state(sock, set.field, coerced)
    end)
  end

  # Evaluate a set value based on its type
  defp evaluate_set_value(%Lavash.Rx{ast: ast}, sock, params) do
    # Build state map from socket state + params (same as template assigns)
    state = Map.merge(LSocket.state(sock), params)
    {result, _} = Code.eval_quoted(ast, [state: state], __ENV__)
    result
  end

  defp evaluate_set_value(fun, sock, params) when is_function(fun, 1) do
    # Legacy function format: fn %{params: params, state: state} -> value end
    fun.(%{params: params, state: LSocket.state(sock)})
  end

  defp evaluate_set_value(literal, _sock, _params) do
    # Literal value
    literal
  end

  @doc """
  Apply run operations to state.

  Each run has a function (as quoted AST) that receives an assigns map (state + params merged)
  and returns updated assigns using Phoenix.Component.assign/3.

  This enables proper change tracking via the assigns mechanism.
  """
  def apply_runs(socket, runs, params, _module) do
    Enum.reduce(runs || [], socket, fn run, sock ->
      state = LSocket.state(sock)
      assigns = Map.merge(state, params) |> Map.put(:__changed__, %{})

      # Compile and execute the function from its AST
      fun = compile_run_fun(run.fun)
      updated_assigns = fun.(assigns)

      # Extract changed fields and apply them to socket
      changed = Map.get(updated_assigns, :__changed__, %{})

      Enum.reduce(changed, sock, fn {field, true}, acc_sock ->
        value = Map.get(updated_assigns, field)
        LSocket.put_state(acc_sock, field, value)
      end)
    end)
  end

  # Compile a function from its quoted AST
  # Caches compiled functions for performance
  defp compile_run_fun(fun_ast) when is_function(fun_ast, 1) do
    # Already compiled (legacy support)
    fun_ast
  end

  defp compile_run_fun(fun_ast) do
    # Fun AST is in the form {:fn, _, [{:->, _, [[arg], body]}]}
    # We need to eval it with Phoenix.Component imported for assign/3
    # Wrap the AST with an import statement
    wrapped_ast =
      quote do
        import Phoenix.Component, only: [assign: 3]
        unquote(fun_ast)
      end

    {fun, _bindings} = Code.eval_quoted(wrapped_ast, [], __ENV__)
    fun
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
