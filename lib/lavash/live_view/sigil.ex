defmodule Lavash.LiveView.Sigil do
  @moduledoc false

  defmacro sigil_H({:<<>>, _meta, [template]}, _modifiers) when is_binary(template) do
    caller = __CALLER__
    module = caller.module

    # Get metadata for token transformation
    metadata =
      try do
        if Code.ensure_loaded?(module) and function_exported?(module, :__lavash__, 1) do
          Lavash.Template.TokenTransformer.build_metadata(module, context: :live_view)
        else
          Lavash.Sigil.get_compile_time_metadata(module, :live_view)
        end
      rescue
        _ -> %{context: :live_view}
      end

    # Compile with Lavash.TagEngine and token transformer
    opts = [
      engine: Lavash.TagEngine,
      file: caller.file,
      line: caller.line + 1,
      caller: caller,
      source: template,
      tag_handler: Phoenix.LiveView.HTMLEngine,
      token_transformer: Lavash.Template.TokenTransformer,
      lavash_metadata: metadata
    ]

    EEx.compile_string(template, opts)
  end
end
