defmodule Lavash.Component.CompilerHelpers do
  @moduledoc """
  Shared compiler utilities for LiveComponent and ClientComponent.

  These helpers are used during compilation to generate colocated JS hooks
  and parse function sources for JS transpilation.
  """

  @doc """
  Parses a function source string to an AST.

  Used to convert captured `run` and `validate` function sources
  back to AST for JS compilation.

  ## Examples

      iex> parse_fn_source("fn x -> x + 1 end")
      {:ok, {:fn, _, ...}}

      iex> parse_fn_source(nil)
      nil
  """
  def parse_fn_source(nil), do: nil

  def parse_fn_source(source) do
    case Code.string_to_quoted(source) do
      {:ok, ast} -> ast
      _ -> nil
    end
  end

  @doc """
  Writes a colocated hook file and returns the hook data for Phoenix.

  This function:
  1. Generates a filename with a content hash for cache busting
  2. Only writes if content changed (avoids unnecessary esbuild rebuilds)
  3. Cleans up old JS files in the module directory
  4. Returns the hook data in the format Phoenix expects

  ## Parameters

  - `env` - The compilation environment (for module name and line number)
  - `full_hook_name` - The full hook name (e.g., "MyApp.Toggle.Toggle")
  - `js_code` - The JavaScript code to write

  ## Returns

  A tuple of `{filename, hook_data}` where hook_data is a map with
  `:name` and `:key` fields for Phoenix's colocated hook system.
  """
  def write_colocated_hook(env, full_hook_name, js_code) do
    target_dir = get_target_dir()
    module_dir = Path.join(target_dir, inspect(env.module))

    # Generate filename with hash for cache busting
    hash = :crypto.hash(:md5, js_code) |> Base.encode32(case: :lower, padding: false)
    filename = "#{env.line}_#{hash}.js"
    full_path = Path.join(module_dir, filename)

    # Ensure directory exists
    File.mkdir_p!(module_dir)

    # Only write if content changed (avoids unnecessary esbuild rebuilds)
    needs_write =
      case File.read(full_path) do
        {:ok, existing} -> existing != js_code
        {:error, _} -> true
      end

    if needs_write do
      # Clean up old files in this module's directory to avoid stale files
      case File.ls(module_dir) do
        {:ok, files} ->
          for file <- files, file != filename, String.ends_with?(file, ".js") do
            File.rm(Path.join(module_dir, file))
          end

        _ ->
          :ok
      end

      # Write the new JS file
      File.write!(full_path, js_code)
    end

    # Return the hook data in the format Phoenix expects
    # key must be a string "hooks" not atom :hooks
    {filename, %{name: full_hook_name, key: "hooks"}}
  end

  @doc """
  Gets the target directory for colocated hooks.

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

  # ============================================
  # Binding Resolution (shared between ClientComponent and LiveComponent)
  # ============================================

  @doc """
  Generates the AST for `__resolve_bindings__/2` function.

  This is used by both ClientComponent and LiveComponent to resolve
  bindings from the `bind` prop in `update/2`.

  Returns quoted code that defines `__resolve_bindings__/2`.
  """
  def generate_binding_resolution_code do
    quote do
      defp __resolve_bindings__(assigns, socket) do
        case Map.get(assigns, :bind) do
          nil ->
            socket

          bindings when is_list(bindings) ->
            # Build a map of local_name -> parent_field
            binding_map =
              Enum.into(bindings, %{}, fn {local, parent} ->
                {local, parent}
              end)

            # Store the binding map for later use in handle_event (server-side routing)
            socket = Phoenix.Component.assign(socket, :__lavash_binding_map__, binding_map)

            # Store client bindings (resolved/flattened) for JS lavash-set events
            # If __lavash_client_bindings__ was passed, use it; otherwise use binding_map
            client_bindings = Map.get(assigns, :__lavash_client_bindings__) || binding_map
            socket = Phoenix.Component.assign(socket, :__lavash_client_bindings__, client_bindings)

            # Store parent CID for routing bound field updates via send_update
            # This is passed when the child is rendered inside a Lavash.Component
            socket =
              case Map.get(assigns, :__lavash_parent_cid__) do
                nil -> socket
                parent_cid -> Phoenix.Component.assign(socket, :__lavash_parent_cid__, parent_cid)
              end

            # Sync parent's optimistic version when bound
            socket =
              case Map.get(assigns, :__lavash_parent_version__) do
                nil -> socket
                parent_version -> Phoenix.Component.assign(socket, :__lavash_version__, parent_version)
              end

            # For each binding, look up the parent's current value
            Enum.reduce(bindings, socket, fn {local, _parent}, sock ->
              value = Map.get(assigns, local)
              Phoenix.Component.assign(sock, local, value)
            end)
        end
      end
    end
  end

  # ============================================
  # Action JS Compilation (shared between ClientComponent and LiveComponent)
  # ============================================

  @doc """
  Generates JS calculation functions from calculation tuples.

  Calculations are tuples: {name, source_string, transformed_expr, deps}
  Each becomes a JS method: `name(state) { return <js_expr>; }`

  ## Example

      generate_calculation_js([{:can_add, "length(@tags) < @max", ast, [:tags, :max]}])
      # => "  can_add(state) {\n    return state.tags.length < state.max;\n  },"
  """
  def generate_calculation_js(calculations) do
    calculations
    |> Enum.map(fn {name, source, _transformed_expr, _deps} ->
      js_expr = Lavash.Rx.Transpiler.to_js(source)
      "  #{name}(state) {\n    return #{js_expr};\n  },"
    end)
    |> Enum.join("\n")
  end

  @doc """
  Converts an Elixir function source string to a JS assignment expression.

  Parses the function source (e.g., "fn tags, tag -> tags ++ [tag] end"),
  extracts the variable names and body, and returns JS code that assigns
  the computed value to `this.state.<field>`.

  ## Parameters

  - `source` - The Elixir function source string
  - `field` - The field name to assign the result to

  ## Example

      fn_source_to_js_assignment("fn tags, tag -> tags ++ [tag] end", :tags)
      # => "this.state.tags = [...current, value];"
  """
  def fn_source_to_js_assignment(source, field) when is_binary(source) do
    case Code.string_to_quoted(source) do
      {:ok, {:fn, _, [{:->, _, [[{current_var, _, _}, {value_var, _, _}], body]}]}} ->
        js_body = Lavash.Rx.Transpiler.to_js(Macro.to_string(body))
        js_body = String.replace(js_body, to_string(current_var), "current")
        js_body = String.replace(js_body, to_string(value_var), "value")
        "this.state.#{field} = #{js_body};"

      _ ->
        "// Could not compile function to JS for #{field}"
    end
  end

  def fn_source_to_js_assignment(nil, field), do: "// No run function for #{field}"

  @doc """
  Converts an Elixir function source string to a JS boolean expression.

  Similar to `fn_source_to_js_assignment/2` but returns just the expression
  without assignment, for use in validation conditions.

  ## Example

      fn_source_to_js_bool("fn tags, tag -> tag not in tags end")
      # => "!current.includes(value)"
  """
  def fn_source_to_js_bool(source) when is_binary(source) do
    case Code.string_to_quoted(source) do
      {:ok, {:fn, _, [{:->, _, [[{current_var, _, _}, {value_var, _, _}], body]}]}} ->
        js_body = Lavash.Rx.Transpiler.to_js(Macro.to_string(body))
        js_body = String.replace(js_body, to_string(current_var), "current")
        js_body = String.replace(js_body, to_string(value_var), "value")
        js_body

      _ ->
        "true"
    end
  end

  def fn_source_to_js_bool(nil), do: "true"

  @doc """
  Converts a simple Elixir function source to a JS return statement.

  Used for simpler action functions where we just need to return the new value.

  ## Supported Patterns

  Simple patterns (string matching):
  - `fn value, _arg -> !value end` → `return !currentValue;`
  - `fn value, _arg -> value + 1 end` → `return currentValue + 1;`
  - `fn value, _arg -> value - 1 end` → `return currentValue - 1;`
  - `fn value, _arg -> value || default end` → `return currentValue || default;`

  Complex patterns (AST-based via Lavash.Rx.Transpiler):
  - Any expression parseable by `Lavash.Rx.Transpiler.to_js/1`

  Falls back to identity function with TODO comment for unrecognized patterns.

  ## Extending This Parser

  To add support for new patterns:
  1. Add a string matching clause for simple cases (like the `+ 1` pattern above)
  2. Or enhance `Lavash.Rx.Transpiler` for complex AST transpilation
  """
  def fn_source_to_js_return(source) when is_binary(source) do
    cond do
      String.contains?(source, "!value") or String.contains?(source, "not value") ->
        "return !currentValue;"

      String.contains?(source, "+ 1") ->
        "return currentValue + 1;"

      String.contains?(source, "- 1") ->
        "return currentValue - 1;"

      # Handle nil coalescing: value || default_value
      String.match?(source, ~r/value\s*\|\|\s*/) ->
        [_, default] = String.split(source, "||", parts: 2)
        default = String.trim(default) |> String.trim_trailing("end") |> String.trim()
        "return currentValue || #{default};"

      true ->
        # Try to parse more complex expressions using the full parser
        case Code.string_to_quoted(source) do
          {:ok, {:fn, _, [{:->, _, [[{current_var, _, _}, {_value_var, _, _}], body]}]}} ->
            js_body = Lavash.Rx.Transpiler.to_js(Macro.to_string(body))
            js_body = String.replace(js_body, to_string(current_var), "currentValue")
            "return #{js_body};"

          _ ->
            # Fallback: identity function with TODO marker
            # To add support for this pattern, extend the pattern matching above
            # or enhance Lavash.Rx.Transpiler for better AST transpilation
            "return currentValue; // TODO: parse #{inspect(source)}"
        end
    end
  end

  def fn_source_to_js_return(nil), do: "return currentValue;"

  @doc """
  Converts an Elixir function source to a JS expression for item-level transformations.

  Used for key-based array mutations where the function receives an item and value,
  and returns an updated item (or :remove).

  ## Supported Patterns

  - `fn item, delta -> %{item | quantity: item.quantity + delta} end`
    → `({...item, quantity: item.quantity + arg})`

  - `fn item, _value -> :remove end` → `'remove'`

  ## Parameters

  - `source` - The Elixir function source string

  ## Returns

  A JS expression that can be used inside a map function.
  Uses `item` for the current item and `arg` for the second argument.

  ## Extending This Parser

  To add support for new patterns:
  1. Extend `transform_map_update_to_js/3` to handle additional AST patterns
  2. Add special case handling in the case statement below
  3. Or implement a full Elixir->JS transpiler (significant undertaking)

  ## Example

      fn_source_to_js_item_transform("fn item, delta -> %{item | quantity: item.quantity + delta} end")
      # => "({...item, quantity: item.quantity + arg})"
  """
  def fn_source_to_js_item_transform(source) when is_binary(source) do
    case Code.string_to_quoted(source) do
      {:ok, {:fn, _, [{:->, _, [[{item_var, _, _}, {arg_var, _, _}], body]}]}} ->
        js_body = transform_map_update_to_js(body, item_var, arg_var)
        js_body

      _ ->
        # Fallback: identity function with TODO marker
        # To add support for this pattern, extend the AST parsing above
        "item // TODO: parse #{inspect(source)}"
    end
  end

  def fn_source_to_js_item_transform(nil), do: "item"

  # Transform Elixir map update syntax to JS object spread
  defp transform_map_update_to_js(body, item_var, arg_var) do
    item_str = to_string(item_var)
    arg_str = to_string(arg_var)

    case body do
      # Handle :remove atom
      :remove ->
        "'remove'"

      # Handle if expression with :remove branch
      {:if, _, [condition, [do: then_branch, else: else_branch]]} ->
        cond_js = transform_expr_to_js(condition, item_str, arg_str)
        then_js = transform_map_update_to_js(then_branch, item_var, arg_var)
        else_js = transform_map_update_to_js(else_branch, item_var, arg_var)
        "(#{cond_js} ? #{then_js} : #{else_js})"

      # Handle map update: %{item | field: value}
      {:%{}, _, [{:|, _, [{^item_var, _, _}, updates]}]} ->
        # Convert updates to JS object spread syntax
        update_parts = Enum.map(updates, fn {key, value} ->
          key_str = to_string(key)
          value_js = transform_expr_to_js(value, item_str, arg_str)
          "#{key_str}: #{value_js}"
        end)
        "({...item, #{Enum.join(update_parts, ", ")}})"

      # Handle plain map: %{key: value, ...}
      {:%{}, _, updates} when is_list(updates) ->
        update_parts = Enum.map(updates, fn {key, value} ->
          key_str = to_string(key)
          value_js = transform_expr_to_js(value, item_str, arg_str)
          "#{key_str}: #{value_js}"
        end)
        "({#{Enum.join(update_parts, ", ")}})"

      # Fallback: try general transpilation
      _ ->
        transform_expr_to_js(body, item_str, arg_str)
    end
  end

  # Transform an expression to JS, replacing item/arg variable names
  defp transform_expr_to_js(expr, item_str, arg_str) do
    js = Lavash.Rx.Transpiler.to_js(Macro.to_string(expr))
    js
    |> String.replace("state.#{item_str}", "item")
    |> String.replace("state.#{arg_str}", "arg")
    |> String.replace(item_str, "item")
    |> String.replace(arg_str, "arg")
  end
end
