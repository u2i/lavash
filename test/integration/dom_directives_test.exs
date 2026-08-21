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

  test "conditional class flips with boolean field (attr derive)", %{session: session} do
    session
    |> visit("/magic/dom-directives")
    |> assert_has(css("#toggle-target.off-class"))
    |> click(css("#toggle-flag"))
    |> assert_has(css("#toggle-target.on-class"))
    |> click(css("#toggle-flag"))
    |> assert_has(css("#toggle-target.off-class"))
  end

  test "list-form class keeps static classes and flips the conditional", %{session: session} do
    # The derive computes a JS array — the compound selectors below
    # fail if the client comma-joins instead of applying Phoenix
    # class-list semantics (e.g. className = "static-class,on-class").
    session
    |> visit("/magic/dom-directives")
    |> assert_has(css("#list-class-target.static-class.off-class"))
    |> click(css("#toggle-flag"))
    |> assert_has(css("#list-class-target.static-class.on-class"))
    |> click(css("#toggle-flag"))
    |> assert_has(css("#list-class-target.static-class.off-class"))
  end

  test "data-lavash-visible: shows/hides via hidden class", %{session: session} do
    # Fixture uses `:if={@hidden_flag}` so when the flag is false the
    # element isn't in the DOM at all. After the toggle, it appears.
    session = visit(session, "/magic/dom-directives")
    refute Wallabidi.Browser.has?(session, Wallabidi.Query.css("#hidden-section"))

    session
    |> click(css("#toggle-hidden"))
    |> assert_has(css("#hidden-section"))
  end

  test "data-lavash-enabled: disables/enables buttons", %{session: session} do
    # enabled_flag starts true → button should not have disabled attr.
    session
    |> visit("/magic/dom-directives")

    refute Wallabidi.Browser.has?(session, Wallabidi.Query.css("#enabled-button[disabled]"))

    session
    |> click(css("#toggle-enabled"))
    |> assert_has(css("#enabled-button[disabled]"))

    # The handler manages the disabled PROPERTY only — no
    # design-system classes sprout from core JS (#126)
    refute Wallabidi.Browser.has?(
             session,
             Wallabidi.Query.css("#enabled-button.opacity-60")
           )
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
