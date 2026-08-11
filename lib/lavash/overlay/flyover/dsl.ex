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

        template do
          ~H"..."
        end
      end

  Parent opens the flyover by binding the open state:

      state :nav_open, :any, from: :ephemeral, default: nil
      action :open_nav do
        set :nav_open, true
      end

      <.lavash_component module={MyApp.NavFlyover} id="nav-flyover"
        open={@nav_open} bind={[open: :nav_open]} />
      <button phx-click="open_nav">Open</button>

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
          "The async assign to wrap with async_result. Inside the template, " <>
            "the assign's own name holds the unwrapped data (e.g. `async_assign " <>
            ":edit_form` makes `@edit_form` the resolved value)."
      ],
      render_closed: [
        type: :boolean,
        default: false,
        doc: """
        Render the panel content even while the overlay is closed. Off by
        default (closed overlays render nothing — the render optimization).
        Turn on when the content is client-renderable (subtree derives over
        optimistic/projected state): the anchors then exist in the DOM, so
        an optimistic open shows COMPLETE content instantly instead of an
        empty panel until the server round-trip.
        """
      ]
    ]
  }

  # template/1 and template_loading/1 are provided by Lavash.Component.RenderImport
  # (via Spark imports in Component.Dsl) and stored in @__lavash_renders__.
  # The GenerateRender transformer reads from that attribute.

  use Spark.Dsl.Extension,
    sections: [@flyover_section],
    transformers: [
      Lavash.Overlay.Flyover.Transformers.InjectState,
      Lavash.Overlay.Flyover.Transformers.GenerateRender
    ]
end
