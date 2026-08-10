defmodule Lavash.Overlay.Modal do
  @moduledoc """
  Modal behavior plugin for Lavash Components.

  This plugin adds modal-specific state management and rendering to a component:

  - Automatic open/close state with a configurable field name
  - `:close` action that sets the open field to nil
  - `:noop` action for backdrop click prevention
  - Helper components for modal chrome

  ## Basic Usage

  The modal chrome (backdrop, panel, animations, async wrapping) is
  generated for you — declare a `template do` block with just the
  content and the `RenderGenerator` builds the full `render/1`:

      defmodule MyApp.EditModal do
        use Lavash.Component, extensions: [Lavash.Overlay.Modal.Dsl]
        import Lavash.Overlay.Modal.Helpers, only: [modal_close_button: 1]

        modal do
          open_field :product_id  # nil = closed, non-nil = open with ID
          async_assign :edit_form # show loading template until this resolves
        end

        read :product, Product do
          id state(:product_id)
        end

        form :edit_form, Product do
          data result(:product)
        end

        actions do
          action :save do
            submit :edit_form, on_success: :close
          end
        end

        template do
          ~H\"\"\"
          <div class="p-6">
            <.modal_close_button id={@__modal_id__} myself={@myself} />
            <.form for={@edit_form} phx-submit="save">
              ...
            </.form>
          </div>
          \"\"\"
        end
      end

  A parent opens the modal by owning a state field bound to the modal's
  open field and setting it (nil = closed, any non-nil value = open):

      state :editing_product_id, :any, from: :ephemeral, default: nil

      actions do
        action :edit_product, [:id] do
          set :editing_product_id, & &1.params.id
        end
      end

      # In the parent template:
      <.lavash_component
        module={MyApp.EditModal}
        id="edit-modal"
        product_id={@editing_product_id}
        bind={[product_id: :editing_product_id]}
      />

  ## Configuration Options

  - `open_field` - The field that controls open state (default: `:open`)
  - `close_on_escape` - Close when escape is pressed (default: `true`)
  - `close_on_backdrop` - Close when clicking backdrop (default: `true`)
  - `max_width` - Modal width: `:sm`, `:md`, `:lg`, `:xl`, `:"2xl"` (default: `:md`)

  ## Injected State & Actions

  The plugin injects:

  1. **State**: `state :open_field, :any, from: :ephemeral, default: nil, animated: [...]`
     (only if not already defined by user; `animated:` adds the
     `{open_field}_phase` field and visibility calculations)

  2. **Action**: `:close` - Sets the open_field to nil
     (merged with user-defined :close if present)

  3. **Action**: `:noop` - Empty action for preventing event propagation
     (only if not already defined)

  ## Helper Components

  The generated render draws the chrome itself; the one helper meant for
  user templates is:

  - `modal_close_button/1` - An x close button
    (`import Lavash.Overlay.Modal.Helpers, only: [modal_close_button: 1]`)
  """

  # This module is a Spark DSL extension - use it via:
  # use Lavash.Component, extensions: [Lavash.Overlay.Modal.Dsl]
  #
  # The actual extension definition is in Lavash.Overlay.Modal.Dsl
end
