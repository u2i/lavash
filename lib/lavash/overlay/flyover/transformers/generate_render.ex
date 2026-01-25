defmodule Lavash.Overlay.Flyover.Transformers.GenerateRender do
  @moduledoc """
  Transformer that generates the render/1 function for flyover components.

  This transformer reads the `render` and `render_loading` entities from the flyover DSL
  and generates a complete render/1 function that:
  1. Wraps content in a static root div (required by LiveView)
  2. Includes the flyover_chrome with proper configuration
  3. Handles async_result for loading states
  """

  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  def after?(Lavash.Overlay.Flyover.Transformers.InjectState), do: true
  def after?(_), do: false
  def before?(_), do: false

  def transform(dsl_state) do
    # Get render functions from top-level entities
    renders = Spark.Dsl.Extension.get_entities(dsl_state, [:renders])

    render_entity = Enum.find(renders, &match?(%Lavash.Overlay.Flyover.Render{}, &1))
    render_loading_entity = Enum.find(renders, &match?(%Lavash.Overlay.Flyover.RenderLoading{}, &1))

    render_template = render_entity && render_entity.template
    render_loading_template = render_loading_entity && render_loading_entity.template

    # If no Spark entity, check for @__lavash_renders__ module attribute
    # This happens when RenderMacro's `render` macro shadows Spark's entity
    module = Transformer.get_persisted(dsl_state, :module)

    {render_template, render_loading_template} =
      if render_template do
        {render_template, render_loading_template}
      else
        lavash_renders = Module.get_attribute(module, :__lavash_renders__) || []
        renders_map = Map.new(lavash_renders)

        # Check for function-based render
        render_fn =
          case Map.get(renders_map, :__render_fn__) do
            nil -> nil
            escaped_fn ->
              # Function-based render - persist the escaped AST
              # DON'T use Code.eval_quoted - that evaluates outside module context
              # and the ~L sigil won't find DSL metadata for forms, etc.
              # RenderGenerator will unquote this into the module code.
              {:render_ast, escaped_fn}
          end

        # Check for render_loading in @__lavash_renders__
        loading_fn =
          case Map.get(renders_map, :__loading_fn__) do
            nil -> render_loading_template
            escaped_fn ->
              # Same pattern for loading - preserve AST for proper compilation
              {:render_ast, escaped_fn}
          end

        {render_fn, loading_fn}
      end

    # Only generate render if a render template is provided
    if render_template do
      open_field = Transformer.get_option(dsl_state, [:flyover], :open_field) || :open
      slide_from = Transformer.get_option(dsl_state, [:flyover], :slide_from) || :right
      close_on_escape = Transformer.get_option(dsl_state, [:flyover], :close_on_escape)
      close_on_backdrop = Transformer.get_option(dsl_state, [:flyover], :close_on_backdrop)
      width = Transformer.get_option(dsl_state, [:flyover], :width)
      height = Transformer.get_option(dsl_state, [:flyover], :height)
      async_assign = Transformer.get_option(dsl_state, [:flyover], :async_assign)

      # Store the render config for the compiler to use
      dsl_state =
        dsl_state
        |> Transformer.persist(:flyover_render_template, render_template)
        |> Transformer.persist(:flyover_render_loading_template, render_loading_template)
        |> Transformer.persist(:flyover_open_field, open_field)
        |> Transformer.persist(:flyover_slide_from, slide_from)
        |> Transformer.persist(:flyover_close_on_escape, close_on_escape)
        |> Transformer.persist(:flyover_close_on_backdrop, close_on_backdrop)
        |> Transformer.persist(:flyover_width, width)
        |> Transformer.persist(:flyover_height, height)
        |> Transformer.persist(:flyover_async_assign, async_assign)
        # Register the render generator for the component compiler
        |> Transformer.persist(:lavash_overlay_render_generator, Lavash.Overlay.Flyover.RenderGenerator)

      {:ok, dsl_state}
    else
      {:ok, dsl_state}
    end
  end
end
