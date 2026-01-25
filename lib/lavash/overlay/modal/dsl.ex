defmodule Lavash.Overlay.Modal.Dsl do
  @moduledoc """
  Spark DSL extension for modal behavior.

  Adds modal-specific state and actions to a Lavash Component:
  - Open/close state management (modal owns its state)
  - Escape key handling
  - Backdrop click handling
  - Auto-injected :close and :noop actions

  ## Usage

      defmodule MyApp.EditModal do
        use Lavash.Component, extensions: [Lavash.Overlay.Modal.Dsl]

        modal do
          open_field :product_id  # nil = closed, non-nil = open with this ID
          close_on_escape true
          close_on_backdrop true
        end

        # Define an :open action for the parent to invoke
        actions do
          action :open, [:product_id] do
            set :product_id, &(&1.params.product_id)
          end
        end

        render fn assigns ->
          ~H"..."
        end
      end

  Parent opens the modal via invoke:

      invoke "my-modal", :open,
        module: MyApp.EditModal,
        params: [product_id: 123]

  The plugin will:
  1. Inject the open_field as ephemeral state (if not already defined)
  2. Inject :close action that sets open_field to nil
  3. Inject :noop action for backdrop click handling
  4. Generate render/1 with modal chrome wrapping your content
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
    target: Lavash.Overlay.Modal.Render,
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
    target: Lavash.Overlay.Modal.RenderLoading,
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
      Lavash.Overlay.Modal.Transformers.InjectState,
      Lavash.Overlay.Modal.Transformers.GenerateRender
    ]
end
