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
    |> visit("/modal-host")
    |> assert_has(css("#open-modal"))
    |> click(css("#open-modal"))
    |> assert_has(css("#modal-content"))
    |> assert_has(css("#modal-content h2", text: "Editing item 123"))
  end

  test "modal renders the item id passed via phx-value-id", %{session: session} do
    # The action :open_modal takes [:id] from phx-value-id="123" and invokes
    # the modal component with that id. The fixture renders "Editing item 123".
    session
    |> visit("/modal-host")
    |> click(css("#open-modal"))
    |> assert_has(css("#modal-content h2", text: "Editing item 123"))
  end

  test "modal is not in the DOM before it has been opened", %{session: session} do
    # When open_field's value is nil (initial state), the modal body should
    # not be rendered. Phase machine: idle -> entering -> visible. At idle the
    # render hasn't been called yet.
    session
    |> visit("/modal-host")
    |> assert_has(css("#open-modal"))

    refute Wallabidi.Browser.has?(session, Wallabidi.Query.css("#modal-content"))
  end

  test "modal close button removes the modal content", %{session: session} do
    session
    |> visit("/modal-host")
    |> click(css("#open-modal"))
    |> assert_has(css("#modal-content"))
    |> click(css("#modal-content button"))

    refute Wallabidi.Browser.has?(session, Wallabidi.Query.css("#modal-content"))
  end

  test "re-opening after close renders again", %{session: session} do
    session
    |> visit("/modal-host")
    |> click(css("#open-modal"))
    |> assert_has(css("#modal-content"))
    |> click(css("#modal-content button"))
    |> click(css("#open-modal"))
    |> assert_has(css("#modal-content"))
  end
end
