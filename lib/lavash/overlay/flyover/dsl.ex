defmodule Lavash.Overlay.Flyover.Dsl do
  @moduledoc """
  Spark DSL extension for flyover (slideover) behavior.

  Adds flyover-specific state and actions to a Lavash Component:
  - Open/close state management (flyover owns its state)
  - Escape key handling
  - Backdrop click handling
  - Slide direction (left, right, top, bottom)
  - Auto-injected :close and :noop actions

  ## Usage

      defmodule MyApp.NavFlyover do
        use Lavash.Component, extensions: [Lavash.Overlay.Flyover.Dsl]

        flyover do
          open_field :open
          slide_from :left
          close_on_escape true
          close_on_backdrop true
        end

        render fn assigns ->
          ~H"..."
        end
      end

  Parent opens the flyover via JS event:

      JS.dispatch("open-panel", to: "#nav-flyover-flyover", detail: %{open: true})

  The plugin will:
  1. Inject the open_field as ephemeral state (if not already defined)
  2. Inject :close action that sets open_field to nil
  3. Inject :noop action for backdrop click handling
  4. Generate render/1 with flyover chrome wrapping your content
  """

  @flyover_section %Spark.Dsl.Section{
    name: :flyover,
    describe: "Flyover behavior configuration",
    schema: [
      open_field: [
        type: :atom,
        default: :open,
        doc: "The field that controls open state. nil = closed, truthy = open."
      ],
      slide_from: [
        type: {:one_of, [:left, :right, :top, :bottom]},
        default: :right,
        doc: "Direction the flyover slides in from"
      ],
      close_on_escape: [
        type: :boolean,
        default: true,
        doc: "Close flyover when escape key is pressed"
      ],
      close_on_backdrop: [
        type: :boolean,
        default: true,
        doc: "Close flyover when clicking the backdrop"
      ],
      width: [
        type: {:one_of, [:sm, :md, :lg, :xl, :full]},
        default: :md,
        doc: "Width of the flyover panel (for left/right slide)"
      ],
      height: [
        type: {:one_of, [:sm, :md, :lg, :xl, :full]},
        default: :md,
        doc: "Height of the flyover panel (for top/bottom slide)"
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
      "The flyover content template. Receives assigns with @form set to the unwrapped async data.",
    target: Lavash.Overlay.Flyover.Render,
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
    target: Lavash.Overlay.Flyover.RenderLoading,
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
    describe: "Flyover render templates",
    entities: [@render_entity, @render_loading_entity]
  }

  use Spark.Dsl.Extension,
    sections: [@flyover_section, @renders_section],
    transformers: [
      Lavash.Overlay.Flyover.Transformers.InjectState,
      Lavash.Overlay.Flyover.Transformers.GenerateRender
    ],
    imports: [Lavash.Sigil]
end
