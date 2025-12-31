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
end
