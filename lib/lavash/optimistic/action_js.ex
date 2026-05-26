defmodule Lavash.Optimistic.ActionJs do
  @moduledoc """
  Shared action analysis and JS generation for optimistic updates.

  Used by both `ColocatedTransformer` (compile-time) and `JsGenerator` (runtime).
  """

  @doc """
  Checks if an action has transpilable client-side operations (sets/updates).

  Actions with effects, submits, navigates, or invokes can still be partially
  optimistic — the sets run client-side immediately while the server
  handles the side effects.
  """
  def action_is_optimistic?(action) do
    has_set = (action.sets || []) != []
    has_map_by = (action.map_bys || []) != []

    # `run` is now post-cascade socket-shape (side-effect-only, not
    # transpilable). `pre_run` could in principle be transpiled to JS
    # the same way the old assigns-shape `run` was — that path isn't
    # wired yet, so for now optimistic eligibility is purely set-driven.
    has_set or has_map_by
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

  def analyze_value(_), do: :unknown

  @doc """
  Normalize a dependency to its root field name as a string.

  Path deps like `{:path, :params, ["name"]}` become `"params"`.
  Atom deps like `:count` become `"count"`.
  """
  def normalize_dep_to_string({:path, root, _path}), do: to_string(root)
  def normalize_dep_to_string(atom) when is_atom(atom), do: to_string(atom)
end
