defmodule Lavash.Component.RenderImport do
  @moduledoc false
  # Re-exports template/1 and template_loading/1 as Spark DSL imports.
  # These store the template source in @__lavash_renders__ for the
  # component compiler and overlay transformers to read.

  # Re-export `template do ~H"..." end` from Lavash.Template.RenderMacro
  # so component DSL users get the same template declaration as LiveView
  # users. See `Lavash.Template.RenderMacro.template/1`.
  defmacro template(do: block) do
    {source, line} = Lavash.Template.RenderMacro.__extract_heex_source__!(block, __CALLER__)
    Lavash.Template.RenderMacro.__build_template_attr__(source, line)
  end

  # Re-export `template_loading do ~H"..." end` from Lavash.Template.RenderMacro
  # so component DSL users get the `template`-shaped loading render alongside the
  # main `template` block. See `Lavash.Template.RenderMacro.template_loading/1`.
  defmacro template_loading(do: block) do
    {source, line} = Lavash.Template.RenderMacro.__extract_heex_source__!(block, __CALLER__)
    Lavash.Template.RenderMacro.__build_loading_attr__(source, line)
  end

  # Re-export `template_trigger do ~H"..." end` — the overlay trigger rendered
  # outside the panel chrome. See `Lavash.Template.RenderMacro.template_trigger/1`.
  defmacro template_trigger(do: block) do
    {source, line} = Lavash.Template.RenderMacro.__extract_heex_source__!(block, __CALLER__)
    Lavash.Template.RenderMacro.__build_trigger_attr__(source, line)
  end
end
