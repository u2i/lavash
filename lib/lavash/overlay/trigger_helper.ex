defmodule Lavash.Overlay.TriggerHelper do
  @moduledoc """
  The button wrapper for `template_trigger do ... end` overlay triggers.

  Renders the user's trigger content inside a `<button>` in normal page
  flow (outside the overlay chrome), wired to:

  - open the overlay optimistically on click (`open-panel` dispatch —
    the same canonical path as programmatic opens)
  - carry the dialog trigger ARIA contract: `aria-haspopup="dialog"`,
    `aria-controls` pointing at the panel, and `aria-expanded`
    (server-rendered from the open field; the client a11y stack keeps
    it current during optimistic open/close)

  The inline style neutralizes UA button chrome without nuking the
  focus outline, so trigger content styles itself (keep it
  non-interactive — spans/icons, not nested buttons or links).
  """

  use Phoenix.Component

  attr(:overlay_id, :string, required: true, doc: "The overlay chrome element id")
  attr(:open, :any, required: true, doc: "The overlay's open value (nil = closed)")
  attr(:render, :any, required: true, doc: "The compiled trigger template fn")
  attr(:all_assigns, :map, required: true, doc: "The component's full assigns")

  def overlay_trigger(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={Phoenix.LiveView.JS.dispatch("open-panel", to: "##{@overlay_id}")}
      aria-haspopup="dialog"
      aria-expanded={to_string(@open != nil)}
      aria-controls={"#{@overlay_id}-panel_content"}
      data-lavash-overlay-trigger={@overlay_id}
      style="background: none; border: none; padding: 0; margin: 0; font: inherit; color: inherit; cursor: pointer;"
    >
      {@render.(@all_assigns)}
    </button>
    """
  end
end
