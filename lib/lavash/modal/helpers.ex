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
          <%!-- Inner content - conditionally rendered, ghost clones this --%>
          <div :if={@is_open} id={"#{@id}-content-inner"}>
            {render_slot(@inner_block)}
          </div>
        </div>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".LavashModal">
      export default {
        mounted() {
          this.wrapper = this.el;
          const id = this.wrapper.id;
          if (!id) {
            console.error("LavashModal: Hook element requires an ID.");
            return;
          }

          this.panelContent = this.wrapper.querySelector(`#${id}-panel`);
          this.overlay = this.wrapper.querySelector(`#${id}-overlay`);
          this.getMainContentInner = () => this.wrapper.querySelector(`#${id}-content-inner`);
          this.getMainContentContainer = () => this.wrapper.querySelector(`#${id}-content`);

          this.isOpen = this.wrapper.dataset.open === "true";
          this.isClosing = false;
          this.ghostElement = null;

          // If already open on mount, run the show animation
          if (this.isOpen) {
            this.wrapper.style.display = "flex";
            this._runShowAnimation();
          }

          // Listen for close-panel event dispatched by user actions
          // This fires BEFORE the server push, so we can start animation immediately
          this.wrapper.addEventListener("close-panel", (e) => {
            this._startCloseAnimation();
          });
        },

        beforeUpdate() {
          this.wasOpen = this.isOpen;
        },

        updated() {
          const wasOpen = this.wasOpen;
          this.isOpen = this.el.dataset.open === "true";

          if (this.isClosing) {
            // Keep modal visible while closing animation runs
            this.wrapper.style.display = "flex";
            return;
          }

          // Opening: show wrapper and animate in
          if (!wasOpen && this.isOpen) {
            this.wrapper.style.display = "flex";
            this._runShowAnimation();
          }

          // Closing without animation (shouldn't happen normally, but handle it)
          if (wasOpen && !this.isOpen && !this.isClosing) {
            this._startCloseAnimation();
          }
        },

        _runShowAnimation() {
          const showModalCmd = this.wrapper.dataset.showModal;
          if (showModalCmd && this.liveSocket) {
            this.liveSocket.execJS(this.wrapper, showModalCmd);
          }
        },

        _startCloseAnimation() {
          // Skip if already animating
          if (this.isClosing) return;

          this.isClosing = true;
          const duration = Number(this.wrapper.dataset.duration) || 200;

          // Keep wrapper visible during animation
          this.wrapper.style.display = "flex";

          // Capture panel dimensions before content changes
          const panelRect = this.panelContent.getBoundingClientRect();

          // Clone content for ghost animation and remove original
          const originalContent = this.getMainContentInner();
          if (originalContent) {
            this.ghostElement = originalContent.cloneNode(true);
            this.ghostElement.removeAttribute("phx-remove");
            this.ghostElement.id = `${this.wrapper.id}-ghost`;
            Object.assign(this.ghostElement.style, {
              pointerEvents: "none",
              zIndex: "61"
            });

            const container = this.getMainContentContainer();
            if (container) {
              // Remove original to prevent flicker - ghost takes its place
              originalContent.remove();
              container.appendChild(this.ghostElement);
            }
          }

          // Lock panel dimensions to prevent reflow when LiveView removes content
          this.panelContent.style.width = `${panelRect.width}px`;
          this.panelContent.style.height = `${panelRect.height}px`;

          // Use LiveView's JS.transition via execJS - targets elements by ID
          const hideModalCmd = this.wrapper.dataset.hideModal;
          if (hideModalCmd && this.liveSocket) {
            requestAnimationFrame(() => {
              this.liveSocket.execJS(this.wrapper, hideModalCmd);
            });
          }

          // Clean up after animation completes
          setTimeout(() => {
            if (this.ghostElement && this.ghostElement.parentNode) {
              this.ghostElement.remove();
            }
            this.ghostElement = null;
            this.isClosing = false;
            this.wrapper.style.display = "none";

            // Reset panel dimensions for next open
            this.panelContent.style.width = "";
            this.panelContent.style.height = "";
          }, duration + 50);
        },

        destroyed() {
          if (this.ghostElement && this.ghostElement.parentNode) {
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
