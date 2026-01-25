defmodule Lavash.Component.Sigil do
  @moduledoc """
  Provides the ~L sigil for Lavash Components with `context: :component`.

  This sigil ensures that component calls get `__lavash_client_bindings__` injected
  for proper binding propagation in nested component hierarchies.

  Note: Only defines `sigil_L`, not `sigil_H`, to avoid conflicts with
  `Phoenix.Component.sigil_H` which is imported via `use Phoenix.Component`.
  """

  @doc """
  Component-specific ~L sigil with context: :component.

  Uses context: :component for proper binding injection in nested components.
  """
  defmacro sigil_L({:<<>>, _meta, [template]}, _modifiers) when is_binary(template) do
    compile_template(template, __CALLER__)
  end

  defp compile_template(template, caller) do
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
