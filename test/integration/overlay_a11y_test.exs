defmodule Lavash.Integration.OverlayA11yTest do
  @moduledoc """
  Overlay accessibility (issue #29), StackedModalsHostLive fixture:
  focus moves into the dialog on open and back to the trigger on
  close, Tab is trapped inside the topmost panel, and Escape closes
  only the topmost of stacked overlays.

  ## Assertion style

  Headless Chrome pages report `document.hasFocus() == false`, so the
  `:focus` CSS pseudo-class never matches even though
  `document.activeElement` tracks focus correctly — assertions go
  through `execute_script` on `activeElement` instead of CSS.

  ## Why async: false

  Focus and the overlay stack are global browser state; concurrent
  tests would fight over them.
  """
  use Lavash.IntegrationCase, async: false

  @panel_a "#stack-modal-a-modal-panel_content"

  defp phase(modal_id, phase) do
    css(~s(#lavash-#{modal_id}[data-modal-phase="#{phase}"]))
  end

  defp eval(session, script) do
    execute_script(session, "return #{script}", fn value -> send(self(), {:eval, value}) end)

    receive do
      {:eval, value} -> value
    after
      2_000 -> :timeout
    end
  end

  defp assert_focus(session, expected_id, tries \\ 40) do
    actual = eval(session, "document.activeElement && document.activeElement.id")

    cond do
      actual == expected_id ->
        session

      tries > 0 ->
        Process.sleep(50)
        assert_focus(session, expected_id, tries - 1)

      true ->
        flunk("expected focus on ##{expected_id}, activeElement is #{inspect(actual)}")
    end
  end

  defp assert_focus_within(session, container_selector, tries \\ 40) do
    script = "document.querySelector('#{container_selector}').contains(document.activeElement)"

    cond do
      eval(session, script) == true ->
        session

      tries > 0 ->
        Process.sleep(50)
        assert_focus_within(session, container_selector, tries - 1)

      true ->
        flunk("expected focus within #{container_selector}")
    end
  end

  test "focus moves into the dialog on open and restores to the trigger on close", %{
    session: session
  } do
    session =
      session
      |> visit("/magic/stacked-modals")
      |> click(css("#open-a"))
      |> assert_has(phase("stack-modal-a", "visible"))

    # First focusable element inside the panel took focus.
    session = assert_focus(session, "a-first")

    # Escape closes and returns focus to the trigger.
    session = send_keys(session, [:escape])
    session = assert_has(session, phase("stack-modal-a", "idle"))
    assert_focus(session, "open-a")
  end

  test "Tab is trapped inside the open panel", %{session: session} do
    session =
      session
      |> visit("/magic/stacked-modals")
      |> click(css("#open-a"))
      |> assert_focus("a-first")

    # Tab: first -> last; Tab again wraps back to first — never out to
    # the page's own buttons.
    session = send_keys(session, [:tab])
    session = assert_focus(session, "a-last")

    session = send_keys(session, [:tab])
    session = assert_focus(session, "a-first")

    # Shift+Tab wraps backwards.
    session = send_keys(session, [:shift, :tab])
    assert_focus(session, "a-last")
  end

  test "Escape closes only the topmost of stacked overlays", %{session: session} do
    session =
      session
      |> visit("/magic/stacked-modals")
      |> click(css("#open-a"))
      |> assert_has(phase("stack-modal-a", "visible"))
      |> click(css("#open-b"))
      |> assert_has(phase("stack-modal-b", "visible"))

    # Topmost (B) owns focus.
    session = assert_focus(session, "b-only")

    # First Escape: B closes, A stays open — focus falls back into A.
    session = send_keys(session, [:escape])
    session = assert_has(session, phase("stack-modal-b", "idle"))
    session = assert_has(session, phase("stack-modal-a", "visible"))
    session = assert_focus_within(session, @panel_a)

    # Second Escape: A closes too, focus restored to its trigger.
    session = send_keys(session, [:escape])
    session = assert_has(session, phase("stack-modal-a", "idle"))
    assert_focus(session, "open-a")
  end

  test "dialog ARIA attributes are present on the panel", %{session: session} do
    session = visit(session, "/magic/stacked-modals")

    assert_has(
      session,
      css(~s(#stack-modal-b-modal-panel_content[role="dialog"][aria-modal="true"]),
        visible: :any
      )
    )
  end
end
