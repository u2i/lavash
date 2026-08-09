defmodule Lavash.Optimistic.JsValidator do
  @moduledoc """
  Compile-time syntax validation for transpiler-generated JavaScript.

  The optimistic transpiler emits colocated JS modules at compile time.
  A transpiler bug that produces syntactically invalid JS would otherwise
  surface only when the consuming app's bundler runs — and a failing
  bundler watcher keeps serving the previous (stale) bundle, so the
  breakage is silent. Validating here turns that failure mode into a
  loud `CompileError` on the module that produced the bad JS.

  Validation shells out to `node --check` on a temp `.mjs` file. When
  node is not on PATH the check is skipped — it is a best-effort safety
  net, not a hard dependency. It can also be disabled explicitly:

      config :lavash, :validate_generated_js, false
  """

  @doc """
  Validate a generated JS module string.

  Returns `:ok` when the JS parses, `:skip` when validation is disabled
  or no validator is available, `{:error, message}` when the JS is
  syntactically invalid.
  """
  @spec validate(String.t()) :: :ok | :skip | {:error, String.t()}
  def validate(js_code) do
    with true <- enabled?(),
         node when is_binary(node) <- System.find_executable("node") do
      check_with_node(node, js_code)
    else
      _ -> :skip
    end
  end

  @doc """
  Validate generated JS for `module`, raising `CompileError` (attributed
  to the module's source file) when the JS does not parse.
  """
  @spec validate!(String.t(), module(), Macro.Env.t()) :: :ok
  def validate!(js_code, module, env) do
    case validate(js_code) do
      {:error, message} ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description: """
          Lavash generated invalid JavaScript for #{inspect(module)}.

          #{message}

          This usually means an optimistic action/calculation contains a
          construct the transpiler mishandles. This is a bug in Lavash —
          please report it with the expression involved.

          To unblock compilation in the meantime, disable compile-time JS
          validation:

              config :lavash, :validate_generated_js, false
          """

      _ ->
        :ok
    end
  end

  defp enabled? do
    Application.get_env(:lavash, :validate_generated_js, true)
  end

  defp check_with_node(node, js_code) do
    hash = :crypto.hash(:md5, js_code) |> Base.encode32(case: :lower, padding: false)
    path = Path.join(System.tmp_dir!(), "lavash_jscheck_#{hash}.mjs")

    try do
      File.write!(path, js_code)

      case System.cmd(node, ["--check", path], stderr_to_stdout: true) do
        {_out, 0} -> :ok
        {out, _status} -> {:error, format_node_error(out, path)}
      end
    after
      File.rm(path)
    end
  end

  # Strip the temp path noise so the error reads as "your generated JS
  # at line N", plus keep node's caret excerpt which shows the offending
  # source line. Matched by filename pattern rather than the exact path
  # because node reports resolved paths (e.g. /private/var/... on macOS).
  defp format_node_error(out, _path) do
    "node --check reported:\n\n" <>
      (out
       |> String.replace(~r|\S*lavash_jscheck_[a-z0-9]+\.mjs|, "generated.mjs")
       |> String.trim()
       |> String.split("\n")
       # Node appends a long stack trace after the syntax excerpt; keep
       # everything up to and including the SyntaxError line.
       |> Enum.take_while(&(not String.starts_with?(String.trim(&1), "at ")))
       |> Enum.join("\n"))
  end
end
