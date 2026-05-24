defmodule Lavash.Integration.DomDirectivesTest do
  @moduledoc """
  `data-lavash-*` attributes — declarative client-side DOM updates that react
  to optimistic state. These tests assert the server-rendered output is
  consistent with the directives after a server round-trip. The fully-client-
  side optimistic path (no round-trip required) lives in a separate suite
  because it needs the optimistic JS hook loaded.
  """
  use Lavash.IntegrationCase, async: false

  test "data-lavash-display: bare @field interpolation renders the value", %{session: session} do
    session
    |> visit("/magic/dom-directives")
    |> assert_has(css("p", text: "Count: 0"))
    |> click(css("#bump"))
    |> assert_has(css("p", text: "Count: 1"))
  end

  test "data-lavash-toggle: class set flips with boolean field", %{session: session} do
    session
    |> visit("/magic/dom-directives")
    |> assert_has(css("#toggle-target.off-class"))
    |> click(css("#toggle-flag"))
    |> assert_has(css("#toggle-target.on-class"))
    |> click(css("#toggle-flag"))
    |> assert_has(css("#toggle-target.off-class"))
  end

  test "data-lavash-visible: shows/hides via hidden class", %{session: session} do
    session
    |> visit("/magic/dom-directives")
    |> assert_has(css("#hidden-section.hidden"))
    |> click(css("#toggle-hidden"))

    refute Wallabidi.Browser.has?(session, Wallabidi.Query.css("#hidden-section.hidden"))
  end

  test "data-lavash-enabled: disables/enables buttons", %{session: session} do
    # enabled_flag starts true → button should not have disabled attr.
    session
    |> visit("/magic/dom-directives")

    refute Wallabidi.Browser.has?(session, Wallabidi.Query.css("#enabled-button[disabled]"))

    session
    |> click(css("#toggle-enabled"))
    |> assert_has(css("#enabled-button[disabled]"))
  end

  test "data-lavash-member: class toggles based on array membership", %{session: session} do
    # items starts as ["one", "two"]; chip-three should be unselected.
    session
    |> visit("/magic/dom-directives")
    |> assert_has(css("#chip-one.selected"))
    |> assert_has(css("#chip-two.selected"))
    |> assert_has(css("#chip-three.unselected"))
    # Toggle "three" in
    |> click(css("#toggle-three"))
    |> assert_has(css("#chip-three.selected"))
    # Toggle "one" out
    |> click(css("#toggle-one"))
    |> assert_has(css("#chip-one.unselected"))
  end

  test "directives stay consistent across multiple state changes", %{session: session} do
    session
    |> visit("/magic/dom-directives")
    |> click(css("#bump"))
    |> click(css("#toggle-flag"))
    |> click(css("#toggle-hidden"))
    |> click(css("#toggle-three"))
    |> assert_has(css("p", text: "Count: 1"))
    |> assert_has(css("#toggle-target.on-class"))
    |> assert_has(css("#chip-three.selected"))
  end
end
