defmodule Lavash.Optimistic.JsValidator do
  @moduledoc """
  Compile-time syntax validation for transpiler-generated JavaScript.

  The optimistic transpiler emits colocated JS modules at compile time.
  A transpiler bug that produces syntactically invalid JS would otherwise
  surface only when the consuming app's bundler runs — and a failing
  bundler watcher keeps serving the previous (stale) bundle, so the
  breakage is silent. Validating here turns that failure mode into a
  loud `CompileError` on the module that produced the bad JS.

  Validation prefers the standalone esbuild binary shipped by the
  `esbuild` hex package (present in nearly every Phoenix app, no node
  required), falling back to `node --check` when esbuild isn't
  available. When neither is, the check is skipped — it is a
  best-effort safety net, not a hard dependency. It can also be
  disabled explicitly:

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
         {_kind, _bin} = validator <- find_validator() do
      check(validator, js_code)
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

  # Prefer the esbuild hex package's standalone binary (no node needed,
  # present in nearly every Phoenix app), then node, else no validator.
  defp find_validator do
    case esbuild_bin() do
      bin when is_binary(bin) ->
        {:esbuild, bin}

      nil ->
        case System.find_executable("node") do
          bin when is_binary(bin) -> {:node, bin}
          nil -> nil
        end
    end
  end

  defp esbuild_bin do
    # Esbuild is not a lavash dependency — it belongs to the consuming
    # app. apply/3 keeps the reference dynamic so lavash compiles
    # cleanly (warnings-as-errors) without it.
    with true <- Code.ensure_loaded?(Esbuild),
         true <- function_exported?(Esbuild, :bin_path, 0),
         bin when is_binary(bin) <- apply(Esbuild, :bin_path, []),
         true <- File.exists?(bin) do
      bin
    else
      _ -> nil
    end
  end

  defp check({kind, bin}, js_code) do
    hash = :crypto.hash(:md5, js_code) |> Base.encode32(case: :lower, padding: false)
    path = Path.join(System.tmp_dir!(), "lavash_jscheck_#{hash}.mjs")

    args =
      case kind do
        # Transform mode: parses the input and prints the result to
        # stdout (discarded). A syntax error exits non-zero with the
        # error text on stderr.
        :esbuild -> [path, "--log-level=error"]
        :node -> ["--check", path]
      end

    try do
      File.write!(path, js_code)

      case System.cmd(bin, args, stderr_to_stdout: true) do
        {_out, 0} -> :ok
        {out, _status} -> {:error, format_error(kind, out)}
      end
    after
      File.rm(path)
    end
  end

  # Strip the temp path noise so the error reads as "your generated JS
  # at line N", keeping the validator's caret excerpt which shows the
  # offending source line. Matched by filename pattern rather than the
  # exact path because node reports resolved paths (e.g.
  # /private/var/... on macOS).
  defp format_error(kind, out) do
    label =
      case kind do
        :esbuild -> "esbuild"
        :node -> "node --check"
      end

    "#{label} reported:\n\n" <>
      (out
       |> String.replace(~r|\S*lavash_jscheck_[a-z0-9]+\.mjs|, "generated.mjs")
       |> String.trim()
       |> String.split("\n")
       # Node appends a long stack trace after the syntax excerpt; keep
       # everything up to and including the SyntaxError line. (esbuild
       # output has no stack trace, so this keeps it whole.)
       |> Enum.take_while(&(not String.starts_with?(String.trim(&1), "at ")))
       |> Enum.join("\n"))
  end
end
