defmodule Lavash.Modal.Dsl do
  @moduledoc """
  Spark DSL extension for modal behavior.

  Adds modal-specific state and actions to a Lavash Component:
  - Open/close state management
  - Escape key handling
  - Backdrop click handling
  - Standard :open, :close, :noop actions

  ## Usage

      defmodule MyApp.EditModal do
        use Lavash.Component
        use Lavash.Modal

        modal do
          # All options have sensible defaults
          open_field :product_id  # nil = closed, non-nil = open with this ID
          close_on_escape true
          close_on_backdrop true
        end

        # The open action is auto-generated, but you can extend it:
        action :open, [:product_id] do
          set :product_id, &(&1.params.product_id)
        end

        # Define your content
        def render_content(assigns) do
          ~H"..."
        end
      end

  The plugin will:
  1. Inject the open_field as an ephemeral input (if not already defined)
  2. Inject :open, :close, :noop actions (merged with user-defined if present)
  3. Wrap render/1 to call render_content/1 inside modal chrome
  """

  @modal_section %Spark.Dsl.Section{
    name: :modal,
    describe: "Modal behavior configuration",
    schema: [
      open_field: [
        type: :atom,
        default: :open,
        doc: "The field that controls open state. nil = closed, truthy = open."
      ],
      close_on_escape: [
        type: :boolean,
        default: true,
        doc: "Close modal when escape key is pressed"
      ],
      close_on_backdrop: [
        type: :boolean,
        default: true,
        doc: "Close modal when clicking the backdrop"
      ],
      max_width: [
        type: {:one_of, [:sm, :md, :lg, :xl, :"2xl"]},
        default: :md,
        doc: "Maximum width of the modal content"
      ],
      async_assign: [
        type: :atom,
        required: false,
        doc:
          "The async assign to wrap with async_result. The unwrapped data is available as @form."
      ]
    ]
  }

  @render_entity %Spark.Dsl.Entity{
    name: :render,
    describe:
      "The modal content template. Receives assigns with @form set to the unwrapped async data.",
    target: Lavash.Modal.Render,
    args: [:template],
    schema: [
      template: [
        type: {:fun, 1},
        required: true,
        doc: "Function (assigns) -> HEEx"
      ]
    ]
  }

  @render_loading_entity %Spark.Dsl.Entity{
    name: :render_loading,
    describe: "Loading state template shown while async data loads",
    target: Lavash.Modal.RenderLoading,
    args: [:template],
    schema: [
      template: [
        type: {:fun, 1},
        required: false,
        doc: "Function (assigns) -> HEEx"
      ]
    ]
  }

  @renders_section %Spark.Dsl.Section{
    name: :renders,
    top_level?: true,
    describe: "Modal render templates",
    entities: [@render_entity, @render_loading_entity]
  }

  use Spark.Dsl.Extension,
    sections: [@modal_section, @renders_section],
    transformers: [
      Lavash.Modal.Transformers.InjectState,
      Lavash.Modal.Transformers.GenerateRender
    ]
end
