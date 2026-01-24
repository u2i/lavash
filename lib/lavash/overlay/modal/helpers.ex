defmodule Lavash.Overlay.Modal.Helpers do
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
  attr(:module, :atom, required: true, doc: "The component module (for logging)")
  attr(:open, :any, required: true, doc: "Controls visibility (truthy = open)")
  attr(:open_field, :atom, default: :open, doc: "The name of the open state field")
  attr(:async_assign, :atom, default: nil, doc: "Async assign to wait for before showing content")
  attr(:myself, :any, required: true, doc: "The component's @myself")
  attr(:close_on_escape, :boolean, default: true)
  attr(:close_on_backdrop, :boolean, default: true)
  attr(:max_width, :atom, default: :md)
  attr(:duration, :integer, default: 200)
  slot(:inner_block, required: true)
  slot(:loading, doc: "Loading content shown during optimistic open")

  def modal_chrome(assigns) do
    max_width_class = Map.get(@max_width_classes, assigns.max_width, "max-w-md")

    # Build the close command: dispatch close-panel event
    # LavashOptimistic on the parent wrapper handles this event
    on_close = JS.dispatch("close-panel", to: "##{assigns.id}")

    # All modal chrome animations are handled by LavashOptimistic via ModalAnimator
    # Chrome elements have JS.ignore_attributes(["class", "style"]) for direct manipulation

    assigns =
      assigns
      |> assign(:max_width_class, max_width_class)
      |> assign(:on_close, on_close)
      |> assign(:is_open, assigns.open != nil)

    ~H"""
    <%!-- Modal chrome wrapper - LavashOptimistic on parent handles animations --%>
    <div
      id={@id}
      class="fixed inset-0 z-50 flex items-center justify-center pointer-events-none invisible"
      phx-mounted={JS.ignore_attributes(["class", "style"])}
      phx-target={@myself}
      data-open-value={Jason.encode!(@open)}
    >
      <%!-- Backdrop overlay - client controls opacity and visibility --%>
      <div
        id={"#{@id}-overlay"}
        phx-mounted={JS.ignore_attributes(["class", "style"])}
        class="absolute inset-0 bg-black opacity-0"
        phx-click={@close_on_backdrop && @on_close}
      />

      <%!-- Panel - client controls opacity/scale/transform via inline styles --%>
      <%!-- Animation classes (opacity-0, scale-95) removed - client owns animation state via style attr --%>
      <div
        id={"#{@id}-panel_content"}
        phx-mounted={JS.ignore_attributes(["class", "style"])}
        class={"inline-grid z-10 bg-base-100 rounded-lg shadow-xl overflow-hidden #{@max_width_class} w-full"}
        style="opacity: 0; transform: scale(0.95)"
        phx-click="noop"
        phx-target={@myself}
        phx-window-keydown={@close_on_escape && @on_close}
        phx-key={@close_on_escape && "Escape"}
      >
        <%!-- Loading content - client controls visibility via class/style --%>
        <div
          :if={@loading != []}
          id={"#{@id}-loading_content"}
          phx-mounted={JS.ignore_attributes(["class", "style"])}
          class="row-start-1 col-start-1 hidden opacity-0 pointer-events-none"
        >
          {render_slot(@loading)}
        </div>
        <%!-- Main content - client controls opacity via class/style --%>
        <div
          id={"#{@id}-main_content"}
          phx-mounted={JS.ignore_attributes(["class", "style"])}
          data-active-if-open={to_string(@is_open)}
          class="row-start-1 col-start-1"
        >
          <div :if={@is_open} id={"#{@id}-main_content_inner"}>
            {render_slot(@inner_block)}
          </div>
        </div>
      </div>
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
    # Only dispatch close-panel event - the hook handles the server push via SyncedVar
    on_close = JS.dispatch("close-panel", to: "##{assigns.id}")

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

      async_assign_field = assigns.async_assign

      assigns =
        assigns
        |> assign(:async_value, async_value)
        |> assign(:async_assign_field, async_assign_field)
        |> assign(:inner_assigns, assigns.assigns)
        |> assign(:render_fn, assigns.render)

      # Only render content when async data is ready.
      # The loading_content div in modal_chrome handles the loading state,
      # so we don't render anything here during loading - this enables FLIP animation
      # to work (loading_content height vs main_content height are different).
      ~H"""
      <.async_result :let={data} assign={@async_value}>
        <:loading></:loading>
        <% render_assigns = assign(@inner_assigns, @async_assign_field, data) %>
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
