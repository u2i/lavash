defmodule Lavash.Overlay.Flyover.Helpers do
  @moduledoc """
  Helper components for flyover (slideover) rendering.

  These components provide the flyover chrome (backdrop, container, slide animations)
  while letting the user define the content.
  """

  use Phoenix.Component
  alias Phoenix.LiveView.JS

  @width_classes %{
    sm: "max-w-sm",
    md: "max-w-md",
    lg: "max-w-lg",
    xl: "max-w-xl",
    full: "max-w-full"
  }

  @height_classes %{
    sm: "max-h-48",
    md: "max-h-96",
    lg: "max-h-[32rem]",
    xl: "max-h-[40rem]",
    full: "max-h-full"
  }

  @doc """
  Renders flyover chrome around content with optimistic slide animations.

  Uses a JavaScript hook that creates a "ghost" copy of the flyover content
  and animates it out, providing smooth transitions even though LiveView
  removes the real element immediately.

  ## Attributes

  - `id` - Unique ID for the flyover (required)
  - `open` - Controls visibility. Flyover shows when truthy.
  - `myself` - The component's @myself for targeting events
  - `slide_from` - Direction: :left, :right, :top, :bottom (default: :right)
  - `close_on_escape` - Whether to close on escape key (default: true)
  - `close_on_backdrop` - Whether to close on backdrop click (default: true)
  - `width` - Width for left/right: :sm, :md, :lg, :xl, :full (default: :md)
  - `height` - Height for top/bottom: :sm, :md, :lg, :xl, :full (default: :md)
  - `duration` - Animation duration in ms (default: 200)

  ## Example

      <.flyover_chrome id="nav-flyover" open={@open} myself={@myself} slide_from={:left}>
        <nav class="p-4">
          <h2>Navigation</h2>
          <ul>...</ul>
        </nav>
      </.flyover_chrome>
  """
  attr(:id, :string, required: true, doc: "Unique ID for the flyover")
  attr(:module, :atom, required: true, doc: "The component module (for logging)")
  attr(:open, :any, required: true, doc: "Controls visibility (truthy = open)")
  attr(:open_field, :atom, default: :open, doc: "The name of the open state field")
  attr(:slide_from, :atom, default: :right, doc: "Direction: :left, :right, :top, :bottom")
  attr(:async_assign, :atom, default: nil, doc: "Async assign to wait for before showing content")
  attr(:myself, :any, required: true, doc: "The component's @myself")
  attr(:close_on_escape, :boolean, default: true)
  attr(:close_on_backdrop, :boolean, default: true)
  attr(:width, :atom, default: :md)
  attr(:height, :atom, default: :md)
  attr(:duration, :integer, default: 200)
  slot(:inner_block, required: true)
  slot(:loading, doc: "Loading content shown during optimistic open")

  def flyover_chrome(assigns) do
    # Get position and size classes based on slide direction
    # transform_value is the CSS transform for the closed state
    {position_class, size_class, transform_value} =
      case assigns.slide_from do
        :left ->
          width_class = Map.get(@width_classes, assigns.width, "max-w-md")
          {"inset-y-0 left-0", "w-full #{width_class}", "translateX(-100%)"}

        :right ->
          width_class = Map.get(@width_classes, assigns.width, "max-w-md")
          {"inset-y-0 right-0", "w-full #{width_class}", "translateX(100%)"}

        :top ->
          height_class = Map.get(@height_classes, assigns.height, "max-h-96")
          {"inset-x-0 top-0", "h-auto #{height_class}", "translateY(-100%)"}

        :bottom ->
          height_class = Map.get(@height_classes, assigns.height, "max-h-96")
          {"inset-x-0 bottom-0", "h-auto #{height_class}", "translateY(100%)"}
      end

    # Build the close command: dispatch close-panel event
    # LavashOptimistic on the parent wrapper handles this event
    on_close = JS.dispatch("close-panel", to: "##{assigns.id}")

    # All flyover chrome animations are handled by LavashOptimistic via FlyoverAnimator
    # Chrome elements have JS.ignore_attributes(["class", "style"]) for direct manipulation

    assigns =
      assigns
      |> assign(:position_class, position_class)
      |> assign(:size_class, size_class)
      |> assign(:transform_value, transform_value)
      |> assign(:on_close, on_close)
      |> assign(:is_open, assigns.open != nil)

    ~H"""
    <%!-- Flyover chrome wrapper - LavashOptimistic on parent handles animations --%>
    <div
      id={@id}
      class="fixed inset-0 z-50 pointer-events-none invisible"
      phx-mounted={JS.ignore_attributes(["class", "style"])}
      phx-target={@myself}
      data-open-value={Jason.encode!(@open)}
      data-slide-from={to_string(@slide_from)}
    >
      <%!-- Backdrop overlay - client controls opacity and visibility --%>
      <div
        id={"#{@id}-overlay"}
        phx-mounted={JS.ignore_attributes(["class", "style"])}
        class="absolute inset-0 bg-black"
        style="opacity: 0"
        phx-click={@close_on_backdrop && @on_close}
      />

      <%!-- Panel - client controls transform via inline styles --%>
      <%!-- Animation classes removed - client owns animation state via style attr --%>
      <%!-- Uses CSS grid to stack loading and main content for crossfade --%>
      <div
        id={"#{@id}-panel_content"}
        phx-mounted={JS.ignore_attributes(["class", "style"])}
        class={"fixed z-10 bg-base-100 shadow-xl overflow-hidden grid #{@position_class} #{@size_class}"}
        style={"transform: #{@transform_value}"}
        phx-click="noop"
        phx-target={@myself}
        phx-window-keydown={@close_on_escape && @on_close}
        phx-key={@close_on_escape && "Escape"}
      >
        <%!-- Loading content - client controls visibility via class/style --%>
        <%!-- Stacked in same grid cell as main content for crossfade effect --%>
        <div
          :if={@loading != []}
          id={"#{@id}-loading_content"}
          phx-mounted={JS.ignore_attributes(["class", "style"])}
          class="row-start-1 col-start-1 h-full hidden opacity-0 pointer-events-none"
        >
          {render_slot(@loading)}
        </div>
        <%!-- Main content - client controls opacity via class/style --%>
        <%!-- Stacked in same grid cell as loading for crossfade effect --%>
        <div
          id={"#{@id}-main_content"}
          phx-mounted={JS.ignore_attributes(["class", "style"])}
          data-active-if-open={to_string(@is_open)}
          class="row-start-1 col-start-1 h-full overflow-auto"
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
  A close button for flyover headers using DaisyUI button classes.

  The button dispatches a `close-panel` event to trigger the slide animation,
  then pushes the "close" event to the server.

  ## Example

      <div class="flex justify-between p-4 border-b">
        <h2>Title</h2>
        <.flyover_close_button id={@__flyover_id__} myself={@myself} />
      </div>
  """
  attr(:id, :string, required: true, doc: "The flyover ID (for targeting the close-panel event)")
  attr(:myself, :any, required: true)
  attr(:class, :string, default: "btn btn-sm btn-circle btn-ghost")

  def flyover_close_button(assigns) do
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
  Default loading template for flyovers.

  Shows a DaisyUI skeleton loader while content loads.
  """
  def default_loading(assigns) do
    ~H"""
    <div class="p-6 space-y-4">
      <div class="skeleton h-6 w-1/3"></div>
      <div class="skeleton h-10 w-full"></div>
      <div class="skeleton h-10 w-full"></div>
      <div class="skeleton h-10 w-full"></div>
    </div>
    """
  end

  @doc """
  Renders flyover content with async_result wrapping if a form is specified.

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

  def flyover_content(assigns) do
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
      # The loading_content div in flyover_chrome handles the loading state,
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
