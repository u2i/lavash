defmodule Lavash.Optimistic.ActionJs do
  @moduledoc """
  Shared action analysis and JS generation for optimistic updates.

  Used by both `ColocatedTransformer` (compile-time) and `JsGenerator` (runtime).
  """

  @doc """
  Checks if an action has transpilable client-side operations (sets/updates).

  Actions with effects, submits, navigates, or invokes can still be partially
  optimistic — the sets/updates run client-side immediately while the server
  handles the side effects.
  """
  def action_is_optimistic?(action) do
    has_set_or_update = (action.sets || []) != [] or (action.updates || []) != []
    has_map_by = (action.map_bys || []) != []

    runs = action.runs || []
    reads = action.reads || []
    has_transpilable_runs = runs != [] and reads != []

    has_set_or_update or has_map_by or has_transpilable_runs
  end

  @doc """
  Analyze a value to determine how to generate JS for it.

  Returns:
  - `{:rx, source}` for rx() expressions
  - `{:literal, value}` for simple literals
  - `:from_params_value` for param accessors
  - `:unknown` for non-transpilable values
  """
  def analyze_value(%Lavash.Rx{source: source}), do: {:rx, source}

  def analyze_value(value)
      when is_number(value) or is_binary(value) or is_boolean(value) or is_atom(value) do
    {:literal, value}
  end

  def analyze_value(value) when is_list(value) do
    if Enum.all?(value, fn v ->
         is_number(v) or is_binary(v) or is_boolean(v) or is_atom(v)
       end) do
      {:literal, value}
    else
      :unknown
    end
  end

  def analyze_value(value) when is_function(value, 1) do
    try do
      test_ctx = %{params: %{value: "__TEST_VALUE__"}, state: %{}}
      result = value.(test_ctx)

      if result == "__TEST_VALUE__" do
        :from_params_value
      else
        :unknown
      end
    rescue
      _ -> :unknown
    end
  end

  def analyze_value(_), do: :unknown

  @doc """
  Analyze an update function to detect increment/decrement patterns.

  Returns `{:increment, n}`, `{:decrement, n}`, or `:unknown`.
  """
  def analyze_update_function(fun) when is_function(fun, 1) do
    try do
      result_0 = fun.(0)
      result_10 = fun.(10)
      result_100 = fun.(100)

      delta1 = result_0 - 0
      delta2 = result_10 - 10
      delta3 = result_100 - 100

      if delta1 == delta2 and delta2 == delta3 do
        if delta1 >= 0 do
          {:increment, delta1}
        else
          {:decrement, -delta1}
        end
      else
        :unknown
      end
    rescue
      _ -> :unknown
    end
  end

  def analyze_update_function(_), do: :unknown

  @doc """
  Generate JS for an update operation (increment/decrement).
  """
  def generate_update_js(update) do
    field = update.field
    fun = update.fun

    case analyze_update_function(fun) do
      {:increment, n} ->
        "#{field}: state.#{field} + #{n}"

      {:decrement, n} ->
        "#{field}: state.#{field} - #{n}"

      :unknown ->
        nil
    end
  end

  @doc """
  Normalize a dependency to its root field name as a string.

  Path deps like `{:path, :params, ["name"]}` become `"params"`.
  Atom deps like `:count` become `"count"`.
  """
  def normalize_dep_to_string({:path, root, _path}), do: to_string(root)
  def normalize_dep_to_string(atom) when is_atom(atom), do: to_string(atom)
end
