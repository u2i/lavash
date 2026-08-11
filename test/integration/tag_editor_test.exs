defmodule Lavash.Integration.TagEditorTest do
  @moduledoc """
  The `data-lavash-action` input primitive end-to-end (TagEditor):
  Enter commits the input's value to the component's `:add` action —
  optimistic chip in-window, input cleared, server persisted — and
  the bound parent state updates in the same tick. Removal is a plain
  optimistic click.

  Regression for #75: the attribute previously had NO implementation
  (nothing listened for it), so Enter silently did nothing.
  """
  use Lavash.IntegrationCase, async: false

  alias Wallabidi.LiveView, as: WLV

  @latency_ms 800

  defp tag_input, do: css(~s([data-lavash-action="add"]))

  defp eval(session, script) do
    execute_script(session, "return #{script}", fn value -> send(self(), {:eval, value}) end)

    receive do
      {:eval, value} -> value
    after
      2_000 -> :timeout
    end
  end

  test "Enter adds a tag optimistically, clears the input, persists", %{session: session} do
    session =
      session
      |> visit("/magic/tag-editor")
      |> WLV.set_latency(@latency_ms)

    session = assert_has(session, css("#host-tags", text: "one"))

    try do
      session = fill_in(session, tag_input(), with: "beans")
      # fill_in sets the value via CDP without focusing; click focuses
      # the input so the global Enter lands on it.
      session = click(session, tag_input())
      session = send_keys(session, [:enter])

      # In-window: the chip rendered, the bound PARENT state updated
      # (cross-hook propagation), and the input cleared for the next tag.
      session = assert_has(session, css("#tags-editor span", text: "beans"))
      session = assert_has(session, css("#host-tags", text: "one,beans"))

      # Cleared for the next tag (value is a DOM property, not an
      # attribute — CSS [value=""] can't see it).
      assert eval(session, ~s{document.querySelector('[data-lavash-action="add"]').value}) == ""

      # After the round-trip the tag persisted (server render agrees).
      session = WLV.await_patch(session)
      session = assert_has(session, css("#host-tags", text: "one,beans"))

      # Removal: optimistic click on a specific chip's ×. The chip must
      # vanish well inside the lag window (round trip is 2×800ms — a
      # 600ms bound proves the client did it, not the server).
      session = click(session, css(~s(#tags-editor button[phx-value-val="one"])), await: :defer)
      refute_has(session, css("#tags-editor span", text: "one", wait: 600))

      session = WLV.await_patch(session)
      assert eval(session, ~s{document.querySelector("#host-tags").textContent}) == "beans"
    after
      _ = WLV.clear_latency(session)
    end
  end

  test "empty input does nothing on Enter", %{session: session} do
    session = visit(session, "/magic/tag-editor")

    session = click(session, tag_input())
    session = send_keys(session, [:enter])

    assert_has(session, css("#host-tags", text: "one"))
  end
end
