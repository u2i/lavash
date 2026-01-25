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
    # Get render functions from top-level entities
    renders = Spark.Dsl.Extension.get_entities(dsl_state, [:renders])

    render_entity = Enum.find(renders, &match?(%Lavash.Overlay.Modal.Render{}, &1))
    render_loading_entity = Enum.find(renders, &match?(%Lavash.Overlay.Modal.RenderLoading{}, &1))

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

        # Check for legacy function-based render
        render_fn =
          case Map.get(renders_map, :__legacy_fn__) do
            nil ->
              # Check for :default from new syntax
              case Map.get(renders_map, :default) do
                %{source: _source} -> nil  # Will be handled by Component compiler
                _ -> nil
              end

            escaped_fn ->
              # Legacy function-based render - persist the escaped AST
              # DON'T use Code.eval_quoted - that evaluates outside module context
              # and the ~L sigil won't find DSL metadata for forms, etc.
              # RenderGenerator will unquote this into the module code.
              {:__legacy_ast__, escaped_fn}
          end

        # Check for render_loading in @__lavash_renders__
        loading_fn =
          case Map.get(renders_map, :loading) do
            nil -> render_loading_template
            escaped_fn when is_tuple(escaped_fn) ->
              # Same pattern for loading - preserve AST for proper compilation
              {:__legacy_ast__, escaped_fn}
            %{source: _source} -> nil
          end

        {render_fn, loading_fn}
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
        |> Transformer.persist(:lavash_overlay_render_generator, Lavash.Overlay.Modal.RenderGenerator)

      {:ok, dsl_state}
    else
      {:ok, dsl_state}
    end
  end
end
