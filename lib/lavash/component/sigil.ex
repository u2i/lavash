defmodule Lavash.Component.Sigil do
  @moduledoc false

  defmacro sigil_H({:<<>>, _meta, [template]}, _modifiers) when is_binary(template) do
    caller = __CALLER__
    module = caller.module

    # Get metadata for token transformation (component context)
    metadata =
      try do
        case Lavash.Sigil.get_compile_time_metadata(module) do
          nil -> %{context: :component}
          m -> Map.put(m, :context, :component)
        end
      rescue
        _ -> %{context: :component}
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
