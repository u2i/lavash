defmodule Lavash.Sigil do
  @moduledoc """
  The `~L` sigil for Lavash HEEx templates.

  Used inside `render fn assigns -> ~L\"\"\"...\"\"\" end` to mark templates
  for Lavash processing. The sigil itself is a no-op — template compilation
  is handled by the transformer pipeline (TokenizeTemplate → AnalyzeTemplate →
  ExtractColocatedJs → CompileComponent/CompileLiveView).

  The sigil exists so that:
  1. Editors can provide HEEx syntax highlighting
  2. `Macro.escape` captures a `{:sigil_L, meta, ...}` AST node that
     `TokenizeTemplate` pattern-matches to extract the template source
  """

  @doc """
  Marks a HEEx template for Lavash processing.

  This macro is a no-op — it returns the compiled HEEx as-is. The actual
  Lavash template processing (attribute injection, JS generation, etc.)
  happens in the Spark transformer pipeline, not in the sigil.
  """
  defmacro sigil_L({:<<>>, _meta, [template]}, _modifiers) when is_binary(template) do
    caller = __CALLER__

    # Compile as standard HEEx — the transformer pipeline handles
    # Lavash-specific processing via pre-tokenized tokens.
    opts = [
      engine: Phoenix.LiveView.TagEngine,
      file: caller.file,
      line: caller.line + 1,
      caller: caller,
      source: template,
      tag_handler: Phoenix.LiveView.HTMLEngine
    ]

    EEx.compile_string(template, opts)
  end
end
