defmodule Lavash.Modal.Helpers do
  @moduledoc """
  Helper components for modal rendering.

  These components provide the modal chrome (backdrop, container, escape handling)
  while letting the user define the content.
  """

  use Phoenix.Component

  @max_width_classes %{
    sm: "max-w-sm",
    md: "max-w-md",
    lg: "max-w-lg",
    xl: "max-w-xl",
    "2xl": "max-w-2xl"
  }

  @doc """
  Renders modal chrome around content using DaisyUI modal classes.

  The modal is only rendered when `open` is truthy.

  ## Attributes

  - `open` - Controls visibility. Modal shows when truthy.
  - `myself` - The component's @myself for targeting events
  - `close_on_escape` - Whether to close on escape key (default: true)
  - `close_on_backdrop` - Whether to close on backdrop click (default: true)
  - `max_width` - Maximum width: :sm, :md, :lg, :xl, :"2xl" (default: :md)

  ## Example

      <.modal_chrome open={@product_id} myself={@myself}>
        <h2>Edit Product</h2>
        <.form ...>...</.form>
      </.modal_chrome>
  """
  attr(:open, :any, required: true, doc: "Controls visibility (truthy = open)")
  attr(:myself, :any, required: true, doc: "The component's @myself")
  attr(:close_on_escape, :boolean, default: true)
  attr(:close_on_backdrop, :boolean, default: true)
  attr(:max_width, :atom, default: :md)
  slot(:inner_block, required: true)

  def modal_chrome(assigns) do
    max_width_class = Map.get(@max_width_classes, assigns.max_width, "max-w-md")
    assigns = assign(assigns, :max_width_class, max_width_class)

    ~H"""
    <div class="contents">
      <dialog
        :if={@open != nil}
        class="modal modal-open"
        phx-window-keydown={@close_on_escape && "close"}
        phx-key={@close_on_escape && "escape"}
        phx-target={@myself}
      >
        <div class={"modal-box #{@max_width_class}"} phx-click="noop" phx-target={@myself}>
          {render_slot(@inner_block)}
        </div>
        <form
          :if={@close_on_backdrop}
          method="dialog"
          class="modal-backdrop"
          phx-click="close"
          phx-target={@myself}
        >
          <button type="button">close</button>
        </form>
      </dialog>
    </div>
    """
  end

  @doc """
  A close button for modal headers using DaisyUI button classes.

  ## Example

      <div class="flex justify-between">
        <h2>Title</h2>
        <.modal_close_button myself={@myself} />
      </div>
  """
  attr(:myself, :any, required: true)
  attr(:class, :string, default: "btn btn-sm btn-circle btn-ghost absolute right-2 top-2")

  def modal_close_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="close"
      phx-target={@myself}
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
