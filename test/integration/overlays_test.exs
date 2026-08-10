defmodule Lavash.Integration.OverlaysTest do
  @moduledoc """
  Modals — overlays driven by the Lavash phase machine. These tests cover the
  server-observable aspects (open via invoke, close, content rendered while
  open). Animation phases (entering/exiting transition timing) require the
  optimistic JS hook and live in a separate suite.
  """
  use Lavash.IntegrationCase, async: false

  test "modal opens when the host's open action fires", %{session: session} do
    session
    |> visit("/magic/modal-host")
    |> assert_has(css("#open-modal"))
    |> click(css("#open-modal"))
    |> assert_has(css("#modal-content"))
    |> assert_has(css("#modal-content h2", text: "Editing item 123"))
  end

  test "modal renders the item id passed via phx-value-id", %{session: session} do
    # The action :open_modal takes [:id] from phx-value-id="123" and invokes
    # the modal component with that id. The fixture renders "Editing item 123".
    session
    |> visit("/magic/modal-host")
    |> click(css("#open-modal"))
    |> assert_has(css("#modal-content h2", text: "Editing item 123"))
  end

  test "modal is not in the DOM before it has been opened", %{session: session} do
    # When open_field's value is nil (initial state), the modal body should
    # not be rendered. Phase machine: idle -> entering -> visible. At idle the
    # render hasn't been called yet.
    session
    |> visit("/magic/modal-host")
    |> assert_has(css("#open-modal"))

    refute Wallabidi.Browser.has?(session, Wallabidi.Query.css("#modal-content"))
  end

  test "modal close button removes the modal content", %{session: session} do
    session
    |> visit("/magic/modal-host")
    |> click(css("#open-modal"))
    |> assert_has(css("#modal-content"))
    |> click(css("#modal-content button"))

    refute Wallabidi.Browser.has?(session, Wallabidi.Query.css("#modal-content"))
  end

  test "re-opening after close renders again", %{session: session} do
    session
    |> visit("/magic/modal-host")
    |> click(css("#open-modal"))
    |> assert_has(css("#modal-content"))
    |> click(css("#modal-content button"))
    |> click(css("#open-modal"))
    |> assert_has(css("#modal-content"))
  end

  test "custom template_loading body renders during the async loading phase", %{session: session} do
    # ModalAsyncComponent declares `template_loading do ~H ... end` with a
    # #modal-async-loading marker. Its async calc sleeps 200ms, so the loading
    # body must show before the resolved content (#modal-async-content) swaps in.
    # This is the only e2e proof that the token-pipeline loading reroute renders.
    session
    |> visit("/magic/modal-async-host")
    |> click(css("#open-modal"))
    |> assert_has(css("#modal-async-loading", text: "Loading item"))
    |> assert_has(css("#modal-async-content"))
    |> assert_has(css("#modal-async-body", text: "Loaded item 42"))
  end

  describe "server-rendered-open modal (issue #30)" do
    test "mount seeds the open value and skips the enter animation", %{session: session} do
      # The open value comes from the URL, so the modal is open in the
      # server-rendered HTML. The hook must seed it as confirmed and jump
      # the phase machine straight to visible — the ~200ms enter animation
      # never runs. wait: 150 is deliberately shorter than the enter
      # duration: the pre-seed behavior (idle → entering → visible at
      # 200ms+) cannot pass it, while the seeded jump is immediate.
      session
      |> visit("/magic/modal-ssr-host?modal_item=42")
      |> assert_has(css(~s([data-modal-phase="visible"]), wait: 150))
      |> assert_has(css("#modal-content h2", text: "Editing item 42"))
    end

    test "seeded modal still closes cleanly", %{session: session} do
      # Guards the seed against leaving the phase machine in a state the
      # close path can't drive (seed bypasses the normal idle → entering
      # transition).
      session
      |> visit("/magic/modal-ssr-host?modal_item=42")
      |> assert_has(css("#modal-content"))
      |> click(css("#modal-content button"))

      refute Wallabidi.Browser.has?(session, Wallabidi.Query.css("#modal-content"))
    end
  end
end
