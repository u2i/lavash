defmodule Lavash.Overlay do
  @moduledoc """
  Overlay components for Lavash - modals, slideovers, and other layered UI.

  Overlays are self-contained UI components that:
  - Layer over existing content
  - Have their own open/close lifecycle
  - Manage animation state
  - Can load async content

  ## Available Overlays

  - `Lavash.Overlay.Modal` - Dialog/modal windows with backdrop

  ## Usage

  Use an overlay as an extension to a Lavash Component:

      defmodule MyApp.EditModal do
        use Lavash.Component, extensions: [Lavash.Overlay.Modal.Dsl]
        import Lavash.Overlay.Modal.Helpers

        modal do
          open_field :product_id
          max_width :lg
        end

        # ... component definition
      end
  """
end
