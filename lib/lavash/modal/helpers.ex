defmodule Lavash.Modal.Helpers do
  @moduledoc """
  Helper components for modal rendering.

  These components provide the modal chrome (backdrop, container, escape handling)
  while letting the user define the content.
  """

  use Phoenix.Component
  alias Phoenix.LiveView.JS

  @max_width_classes %{
    sm: "max-w-sm",
    md: "max-w-md",
    lg: "max-w-lg",
    xl: "max-w-xl",
    "2xl": "max-w-2xl"
  }

  @doc """
  Renders modal chrome around content with optimistic close animations.

  Uses a JavaScript hook that creates a "ghost" copy of the modal content
  and animates it out, providing smooth transitions even though LiveView
  removes the real element immediately.

  ## Attributes

  - `id` - Unique ID for the modal (required)
  - `open` - Controls visibility. Modal shows when truthy.
  - `myself` - The component's @myself for targeting events
  - `close_on_escape` - Whether to close on escape key (default: true)
  - `close_on_backdrop` - Whether to close on backdrop click (default: true)
  - `max_width` - Maximum width: :sm, :md, :lg, :xl, :"2xl" (default: :md)
  - `duration` - Animation duration in ms (default: 200)

  ## Example

      <.modal_chrome id="edit-modal" open={@product_id} myself={@myself}>
        <h2>Edit Product</h2>
        <.form ...>...</.form>
      </.modal_chrome>
  """
  attr(:id, :string, required: true, doc: "Unique ID for the modal")
  attr(:open, :any, required: true, doc: "Controls visibility (truthy = open)")
  attr(:myself, :any, required: true, doc: "The component's @myself")
  attr(:close_on_escape, :boolean, default: true)
  attr(:close_on_backdrop, :boolean, default: true)
  attr(:max_width, :atom, default: :md)
  attr(:duration, :integer, default: 200)
  slot(:inner_block, required: true)
  slot(:loading, doc: "Loading content shown during optimistic open")

  def modal_chrome(assigns) do
    max_width_class = Map.get(@max_width_classes, assigns.max_width, "max-w-md")
    duration = assigns.duration

    # Build the close command: dispatch close-panel (triggers animation) + push close event
    on_close =
      JS.dispatch("close-panel", to: "##{assigns.id}")
      |> JS.push("close", target: assigns.myself)

    # Show animation - applied when modal opens
    show_modal_js =
      JS.transition(
        {"transition-all duration-#{duration} ease-out", "opacity-0 scale-95",
         "opacity-100 scale-100"},
        time: duration,
        to: "##{assigns.id}-panel",
        blocking: false
      )
      |> JS.transition(
        {"transition-opacity duration-#{duration} ease-out", "opacity-0", "opacity-50"},
        time: duration,
        to: "##{assigns.id}-overlay",
        blocking: false
      )

    # Hide animation - targets elements by ID, called via execJS from hook
    hide_modal_js =
      JS.transition(
        {"transition-all duration-#{duration} ease-out", "opacity-100 scale-100",
         "opacity-0 scale-95"},
        time: duration,
        to: "##{assigns.id}-panel",
        blocking: false
      )
      |> JS.transition(
        {"transition-opacity duration-#{duration} ease-out", "opacity-50", "opacity-0"},
        time: duration,
        to: "##{assigns.id}-overlay",
        blocking: false
      )

    assigns =
      assigns
      |> assign(:max_width_class, max_width_class)
      |> assign(:on_close, on_close)
      |> assign(:show_modal_js, show_modal_js)
      |> assign(:hide_modal_js, hide_modal_js)
      |> assign(:is_open, assigns.open != nil)

    ~H"""
    <%!-- Wrapper for hook - always present, hook controls visibility --%>
    <div
      id={@id}
      class="fixed inset-0 z-50 flex items-center justify-center"
      style={!@is_open && "display: none"}
      phx-hook=".LavashModal"
      data-duration={@duration}
      data-open={to_string(@is_open)}
      data-show-modal={@show_modal_js}
      data-hide-modal={@hide_modal_js}
    >
      <%!-- Backdrop overlay - starts invisible, hook animates in --%>
      <div
        id={"#{@id}-overlay"}
        class="absolute inset-0 bg-black/50 opacity-0"
        phx-click={@close_on_backdrop && @on_close}
      />

      <%!-- Panel - starts invisible, hook animates in --%>
      <div
        id={"#{@id}-panel"}
        class={"relative z-10 bg-base-100 rounded-lg shadow-xl #{@max_width_class} w-full opacity-0 scale-95"}
        phx-click="noop"
        phx-target={@myself}
        phx-window-keydown={@close_on_escape && @on_close}
        phx-key={@close_on_escape && "Escape"}
      >
        <%!-- Content container - always present so ghost can be appended --%>
        <div id={"#{@id}-content"} data-open={to_string(@is_open)}>
          <%!-- Loading content - shown during optimistic open before server responds --%>
          <div :if={@loading != []} id={"#{@id}-loading"} style="display: none;">
            {render_slot(@loading)}
          </div>
          <%!-- Inner content - conditionally rendered, ghost clones this --%>
          <div :if={@is_open} id={"#{@id}-content-inner"}>
            {render_slot(@inner_block)}
          </div>
        </div>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".LavashModal">
      // State machine states:
      // - closed: Modal hidden, waiting for open request
      // - opening: Animating in, showing loading, waiting for server
      // - open: Fully open with content
      // - closing: Animating out with ghost, waiting for server confirmation

      export default {
        mounted() {
          const id = this.el.id;
          if (!id) {
            console.error("LavashModal: Hook element requires an ID.");
            return;
          }

          this.panelContent = this.el.querySelector(`#${id}-panel`);
          this.overlay = this.el.querySelector(`#${id}-overlay`);
          this.getContentContainer = () => this.el.querySelector(`#${id}-content`);
          this.getContentInner = () => this.el.querySelector(`#${id}-content-inner`);
          this.getLoadingElement = () => this.el.querySelector(`#${id}-loading`);

          this.state = "closed";
          this.ghostElement = null;
          this.duration = Number(this.el.dataset.duration) || 200;

          // Check if already open on mount (e.g., page refresh with open modal)
          if (this.el.dataset.open === "true") {
            this._transitionTo("open");
          }

          // Listen for open-panel event (optimistic open before server responds)
          this.el.addEventListener("open-panel", () => {
            if (this.state === "closed") {
              this._transitionTo("opening");
            }
          });

          // Listen for close-panel event (optimistic close before server responds)
          this.el.addEventListener("close-panel", () => {
            if (this.state === "open" || this.state === "opening") {
              this._transitionTo("closing");
            }
          });
        },

        beforeUpdate() {
          this.wasServerOpen = this.el.dataset.open === "true";
        },

        updated() {
          const serverOpen = this.el.dataset.open === "true";

          // Server confirmed open
          if (!this.wasServerOpen && serverOpen) {
            if (this.state === "opening") {
              // Already opening optimistically, just transition to open
              this._transitionTo("open");
            } else if (this.state === "closed") {
              // Non-optimistic open (server initiated)
              this._transitionTo("open");
            }
          }

          // Server confirmed close
          if (this.wasServerOpen && !serverOpen) {
            if (this.state === "closing") {
              // Already closing, animation handles cleanup
            } else if (this.state === "open" || this.state === "opening") {
              // Server closed without user action
              this._transitionTo("closing");
            }
          }
        },

        _transitionTo(newState) {
          const oldState = this.state;
          this.state = newState;

          switch (newState) {
            case "opening":
              this._enterOpening();
              break;
            case "open":
              this._enterOpen(oldState);
              break;
            case "closing":
              this._enterClosing();
              break;
            case "closed":
              this._enterClosed();
              break;
          }
        },

        _enterOpening() {
          // Show modal immediately with loading state
          this.el.style.display = "flex";

          // Show loading element if present
          const loading = this.getLoadingElement();
          if (loading) {
            loading.style.display = "block";
          }

          // Run show animation
          const showCmd = this.el.dataset.showModal;
          if (showCmd && this.liveSocket) {
            this.liveSocket.execJS(this.el, showCmd);
          }
        },

        _enterOpen(fromState) {
          this.el.style.display = "flex";

          // Hide loading element
          const loading = this.getLoadingElement();
          if (loading) {
            loading.style.display = "none";
          }

          // If coming from closed (non-optimistic), run show animation
          if (fromState === "closed") {
            const showCmd = this.el.dataset.showModal;
            if (showCmd && this.liveSocket) {
              this.liveSocket.execJS(this.el, showCmd);
            }
          }
          // If coming from opening, animation already running
        },

        _enterClosing() {
          // Keep visible during animation
          this.el.style.display = "flex";

          // Capture panel dimensions
          const panelRect = this.panelContent.getBoundingClientRect();

          // Create ghost from current content
          const content = this.getContentInner();
          if (content) {
            this.ghostElement = content.cloneNode(true);
            this.ghostElement.removeAttribute("phx-remove");
            this.ghostElement.id = `${this.el.id}-ghost`;
            this.ghostElement.style.pointerEvents = "none";
            this.ghostElement.style.zIndex = "61";

            const container = this.getContentContainer();
            if (container) {
              content.remove();
              container.appendChild(this.ghostElement);
            }
          }

          // Lock panel dimensions
          this.panelContent.style.width = `${panelRect.width}px`;
          this.panelContent.style.height = `${panelRect.height}px`;

          // Run hide animation
          const hideCmd = this.el.dataset.hideModal;
          if (hideCmd && this.liveSocket) {
            requestAnimationFrame(() => {
              this.liveSocket.execJS(this.el, hideCmd);
            });
          }

          // Cleanup after animation
          setTimeout(() => {
            this._transitionTo("closed");
          }, this.duration + 50);
        },

        _enterClosed() {
          // Cleanup ghost
          if (this.ghostElement?.parentNode) {
            this.ghostElement.remove();
          }
          this.ghostElement = null;

          // Hide and reset
          this.el.style.display = "none";
          this.panelContent.style.width = "";
          this.panelContent.style.height = "";
        },

        destroyed() {
          if (this.ghostElement?.parentNode) {
            this.ghostElement.remove();
          }
        }
      };
      </script>
    </div>
    """
  end

  @doc """
  A close button for modal headers using DaisyUI button classes.

  The button dispatches a `close-panel` event to trigger the ghost animation,
  then pushes the "close" event to the server.

  ## Example

      <div class="flex justify-between">
        <h2>Title</h2>
        <.modal_close_button id={@__modal_id__} myself={@myself} />
      </div>
  """
  attr(:id, :string, required: true, doc: "The modal ID (for targeting the close-panel event)")
  attr(:myself, :any, required: true)
  attr(:class, :string, default: "btn btn-sm btn-circle btn-ghost absolute right-2 top-2")

  def modal_close_button(assigns) do
    on_close =
      JS.dispatch("close-panel", to: "##{assigns.id}")
      |> JS.push("close", target: assigns.myself)

    assigns = assign(assigns, :on_close, on_close)

    ~H"""
    <button
      type="button"
      phx-click={@on_close}
      class={@class}
      aria-label="Close"
    >
      ✕
    </button>
    """
  end

  @doc """
  Default loading template for modals.

  Shows a DaisyUI skeleton loader while content loads.
  """
  def default_loading(assigns) do
    ~H"""
    <div class="p-6 space-y-4">
      <div class="skeleton h-6 w-1/3"></div>
      <div class="skeleton h-10 w-full"></div>
      <div class="skeleton h-10 w-full"></div>
    </div>
    """
  end

  @doc """
  Renders modal content with async_result wrapping if a form is specified.

  This component handles the async loading state automatically:
  - If `form_field` is specified, wraps content in `<.async_result>`
  - Shows loading template while the form data loads
  - Passes the unwrapped form to the render function
  """
  attr(:assigns, :map, required: true, doc: "The full assigns map")

  attr(:async_assign, :atom,
    required: true,
    doc: "The async assign to wrap with async_result (or nil)"
  )

  attr(:render, :any, required: true, doc: "Function (assigns) -> HEEx")
  attr(:loading, :any, required: true, doc: "Function (assigns) -> HEEx for loading state")

  def modal_content(assigns) do
    if assigns.async_assign do
      # Get the async assign value
      async_value = Map.get(assigns.assigns, assigns.async_assign)

      assigns =
        assigns
        |> assign(:async_value, async_value)
        |> assign(:inner_assigns, assigns.assigns)
        |> assign(:render_fn, assigns.render)

      ~H"""
      <.async_result :let={data} assign={@async_value}>
        <:loading>
          {@loading.(@inner_assigns)}
        </:loading>
        <% render_assigns = assign(@inner_assigns, :form, data) %>
        {@render_fn.(render_assigns)}
      </.async_result>
      """
    else
      # No async assign, just render directly
      ~H"""
      {@render.(@assigns)}
      """
    end
  end
end
