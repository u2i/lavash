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

  # Re-export `template do ~H"..." end` from Lavash.Template.RenderMacro
  # so component DSL users get the same template-declaration alternative
  # as LiveView users. See `Lavash.Template.RenderMacro.template/1` for
  # docs and limitations (no `render_loading` / `set_animated` support).
  defmacro template(do: block) do
    {source, line} = Lavash.Template.RenderMacro.__extract_heex_source__!(block, __CALLER__)
    Lavash.Template.RenderMacro.__build_template_attr__(source, line)
  end
end
