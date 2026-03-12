defmodule Lavash.Component.RenderImport do
  @moduledoc false
  # Re-exports render/1 and render_loading/1 as Spark DSL imports.
  # These store the AST in @__lavash_renders__ for the component
  # compiler and modal transformer to read.

  defmacro render(render_fn) do
    escaped_ast = Macro.escape(render_fn)

    quote do
      @__lavash_renders__ {:__render_fn__, unquote(escaped_ast)}
    end
  end

  defmacro render_loading(render_fn) do
    escaped_ast = Macro.escape(render_fn)

    quote do
      @__lavash_renders__ {:__loading_fn__, unquote(escaped_ast)}
    end
  end
end
