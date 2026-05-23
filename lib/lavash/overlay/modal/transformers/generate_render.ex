defmodule Lavash.Overlay.Modal.Transformers.GenerateRender do
  @moduledoc """
  Transformer that generates the render/1 function for modal components.

  This transformer reads the `render` and `render_loading` entities from the modal DSL
  and generates a complete render/1 function that:
  1. Wraps content in a static root div (required by LiveView)
  2. Includes the modal_chrome with proper configuration
  3. Handles async_result for loading states
  """

  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  def after?(Lavash.Overlay.Modal.Transformers.InjectState), do: true
  def after?(_), do: false
  def before?(_), do: false

  def transform(dsl_state) do
    # Read render functions from @__lavash_renders__ module attribute
    # (set by Lavash.Component.RenderImport macros)
    module = Transformer.get_persisted(dsl_state, :module)
    lavash_renders = Module.get_attribute(module, :__lavash_renders__) || []
    renders_map = Map.new(lavash_renders)

    render_template =
      case Map.get(renders_map, :__render_fn__) do
        nil -> nil
        escaped_fn -> {:render_ast, escaped_fn}
      end

    render_loading_template =
      case Map.get(renders_map, :__loading_fn__) do
        nil -> nil
        escaped_fn -> {:render_ast, escaped_fn}
      end

    # Only generate render if a render template is provided
    if render_template do
      open_field = Transformer.get_option(dsl_state, [:modal], :open_field) || :open
      close_on_escape = Transformer.get_option(dsl_state, [:modal], :close_on_escape)
      close_on_backdrop = Transformer.get_option(dsl_state, [:modal], :close_on_backdrop)
      max_width = Transformer.get_option(dsl_state, [:modal], :max_width)
      async_assign = Transformer.get_option(dsl_state, [:modal], :async_assign)

      # Store the render config for the compiler to use
      dsl_state =
        dsl_state
        |> Transformer.persist(:modal_render_template, render_template)
        |> Transformer.persist(:modal_render_loading_template, render_loading_template)
        |> Transformer.persist(:modal_open_field, open_field)
        |> Transformer.persist(:modal_close_on_escape, close_on_escape)
        |> Transformer.persist(:modal_close_on_backdrop, close_on_backdrop)
        |> Transformer.persist(:modal_max_width, max_width)
        |> Transformer.persist(:modal_async_assign, async_assign)
        # Register the render generator for the component compiler
        |> Transformer.persist(
          :lavash_overlay_render_generator,
          Lavash.Overlay.Modal.RenderGenerator
        )

      {:ok, dsl_state}
    else
      {:ok, dsl_state}
    end
  end
end
