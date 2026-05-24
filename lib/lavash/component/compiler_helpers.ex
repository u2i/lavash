defmodule Lavash.Component.CompilerHelpers do
  @moduledoc """
  Shared compiler utilities for Lavash components.
  """

  @doc """
  Gets the target directory for colocated hooks/JS.

  Matches Phoenix's logic for the target directory, checking the
  `:phoenix_live_view` config for `:colocated_js` settings.
  """
  def get_target_dir do
    default = Path.join(Mix.Project.build_path(), "phoenix-colocated")
    app = to_string(Mix.Project.config()[:app])

    Application.get_env(:phoenix_live_view, :colocated_js, [])
    |> Keyword.get(:target_directory, default)
    |> Path.join(app)
  end

  @doc """
  Converts an Elixir function source to a JS expression for item-level transformations.

  Used for key-based array mutations (`map_by`) where the function receives
  an item and value, and returns an updated item (or :remove).

  ## Examples

      fn_source_to_js_item_transform("fn item, _id -> %{item | quantity: item.quantity + 1} end")
      # => "({...item, quantity: item.quantity + 1})"
  """
  def fn_source_to_js_item_transform(source) when is_binary(source) do
    case Code.string_to_quoted(source) do
      {:ok, {:fn, _, [{:->, _, [[{item_var, _, _}, {arg_var, _, _}], body]}]}} ->
        transform_map_update_to_js(body, item_var, arg_var)

      _ ->
        "item // TODO: parse #{inspect(source)}"
    end
  end

  def fn_source_to_js_item_transform(nil), do: "item"

  # Transform Elixir map update syntax to JS object spread
  defp transform_map_update_to_js(body, item_var, arg_var) do
    item_str = to_string(item_var)
    arg_str = to_string(arg_var)

    case body do
      :remove ->
        "'remove'"

      {:if, _, [condition, [do: then_branch, else: else_branch]]} ->
        cond_js = transform_expr_to_js(condition, item_str, arg_str)
        then_js = transform_map_update_to_js(then_branch, item_var, arg_var)
        else_js = transform_map_update_to_js(else_branch, item_var, arg_var)
        "(#{cond_js} ? #{then_js} : #{else_js})"

      {:%{}, _, [{:|, _, [{^item_var, _, _}, updates]}]} ->
        update_parts =
          Enum.map(updates, fn {key, value} ->
            key_str = to_string(key)
            value_js = transform_expr_to_js(value, item_str, arg_str)
            "#{key_str}: #{value_js}"
          end)

        "({...item, #{Enum.join(update_parts, ", ")}})"

      {:%{}, _, updates} when is_list(updates) ->
        update_parts =
          Enum.map(updates, fn {key, value} ->
            key_str = to_string(key)
            value_js = transform_expr_to_js(value, item_str, arg_str)
            "#{key_str}: #{value_js}"
          end)

        "({#{Enum.join(update_parts, ", ")}})"

      _ ->
        transform_expr_to_js(body, item_str, arg_str)
    end
  end

  defp transform_expr_to_js(expr, item_str, arg_str) do
    js = Lavash.Rx.Transpiler.to_js(Macro.to_string(expr))

    js
    |> String.replace("state.#{item_str}", "item")
    |> String.replace("state.#{arg_str}", "arg")
    |> String.replace(item_str, "item")
    |> String.replace(arg_str, "arg")
  end

  @doc """
  Whether an Ash resource module is compiled and available.

  Uses `Code.ensure_compiled/1` (which waits for parallel compilation to
  finish) rather than `Code.ensure_loaded?/1`. Safe for use from transformers
  because Ash resources never depend on Lavash LiveViews/Components — no
  circular-dependency risk.
  """
  def resource_available?(resource) do
    match?({:module, _}, Code.ensure_compiled(resource)) and
      function_exported?(resource, :spark_dsl_config, 0)
  end
end
