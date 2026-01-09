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

      {:ok, dsl_state}
    else
      {:ok, dsl_state}
    end
  end
end
