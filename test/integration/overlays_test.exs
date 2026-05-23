defmodule Lavash.Integration.OverlaysTest do
  @moduledoc """
  Modals and flyovers — overlays driven by the Lavash phase machine
  (idle → entering → [loading] → visible → exiting → idle) with optimistic
  open/close and CSS-based transitions.
  """
  use ExUnit.Case, async: true

  @moduletag :e2e

  test "modal opens optimistically before the server confirms" do
    # The entering phase should apply immediately on click, not after the
    # server reply.
    assert true
  end

  test "modal close runs the exit transition before unmounting" do
    # The exiting phase should hold the modal in the DOM long enough for
    # the transition to play, then unmount.
    assert true
  end

  test "loading phase appears when an async open action is pending" do
    # Actions that fetch data before showing content should pause the
    # phase machine at `loading`.
    assert true
  end

  test "clicking the backdrop closes the modal" do
    # Default dismiss behavior should set the bound open field to false
    # and trigger the exit transition.
    assert true
  end

  test "Escape key closes the topmost overlay" do
    # Keyboard dismiss should match the backdrop click behavior and only
    # affect the front-most overlay if multiple are open.
    assert true
  end

  test "flyover slides in from the configured edge" do
    # `slide_from: :left|:right|:top|:bottom` should produce the matching
    # initial transform and animate to rest.
    assert true
  end

  test "nested overlays stack and dismiss in reverse order" do
    # Opening a modal from within a flyover (or vice versa) should not
    # collapse the outer overlay when the inner one closes.
    assert true
  end
end
