defmodule Lavash.Integration.UrlStateTest do
  @moduledoc """
  URL-backed state — same contract whether the field is declared via the DSL
  (`state :count, from: :url`) or wired by hand in `handle_params`. Both
  paths should hydrate from the URL on mount and reflect mutations in the
  rendered DOM.

  The FilterLive block covers URL *write-back* from input-driven
  setters (`phx-change` forms), which is client-side
  (history.replaceState in the optimistic hook) — the server
  deliberately never patches the URL.
  """
  use Lavash.IntegrationCase, async: false

  alias Wallabidi.LiveView, as: WLV

  for {label, prefix} <- [{"magic", "/magic"}, {"explicit", "/explicit"}] do
    @prefix prefix

    describe "URL state (#{label})" do
      test "mutating a url-backed field updates the rendered count", %{session: session} do
        session
        |> visit(@prefix <> "/counter")
        |> assert_has(css("#count", text: "0"))
        |> click(css("#inc"))
        |> assert_has(css("#count", text: "1"))

        assert current_url(session) =~ "/counter"
      end

      test "deep-linking a URL hydrates state on mount", %{session: session} do
        session
        |> visit(@prefix <> "/counter?count=7")
        |> assert_has(css("#count", text: "7"))
      end

      test "deep link + click increments from the URL-provided value", %{session: session} do
        session
        |> visit(@prefix <> "/counter?count=42")
        |> assert_has(css("#count", text: "42"))
        |> click(css("#inc"))
        |> assert_has(css("#count", text: "43"))
      end

      test "re-visiting with a different URL param picks up the new value", %{session: session} do
        session
        |> visit(@prefix <> "/counter?count=10")
        |> assert_has(css("#count", text: "10"))
        |> visit(@prefix <> "/counter?count=20")
        |> assert_has(css("#count", text: "20"))
      end
    end
  end

  describe "URL write-back (magic only — client-side history.replaceState)" do
    test "clicking an action that sets url state writes the param back", %{session: session} do
      session =
        session
        |> visit("/magic/counter")
        |> click(css("#inc"))
        |> assert_has(css("#count", text: "1"))

      # The historical gap: this suite asserted the URL contained
      # "/counter" but never that mutations wrote params back.
      assert current_url(session) =~ "count=1"
    end
  end

  describe "phx-change setter forms write the URL (the /demos/products shape)" do
    test "input and selects land in the URL in-window; tri-state clears the param", %{
      session: session
    } do
      session =
        session
        |> visit("/magic/filters")
        |> WLV.set_latency(800)

      try do
        # Text input: the optimistic setter applies (display span) and
        # the URL carries the filter — both client-side, deep inside
        # the lag window (the debounced server push hasn't replied).
        session = fill_in(session, css("#search"), with: "beans")
        session = assert_has(session, css("#s-search", text: "beans"))
        assert current_url(session) =~ "search=beans"

        session = click(session, css("#flag option[value='true']", visible: :any), await: :defer)
        session = assert_has(session, css("#s-flag", text: "true"))
        assert current_url(session) =~ "flag=true"

        session = click(session, css("#min option[value='2']", visible: :any), await: :defer)
        session = assert_has(session, css("#s-min", text: "2"))
        assert current_url(session) =~ "min=2"

        # Tri-state boolean: "All" clears to nil — the param disappears
        # (a false here would filter to No instead of clearing).
        session = click(session, css("#flag option[value='']", visible: :any), await: :defer)
        session = assert_has(session, css("#s-flag", text: "unset"))
        refute current_url(session) =~ "flag="
        assert current_url(session) =~ "search=beans"
      after
        _ = WLV.clear_latency(session)
      end
    end

    test "deep link hydrates all filters", %{session: session} do
      session
      |> visit("/magic/filters?search=x&flag=true&min=3")
      |> assert_has(css("#s-search", text: "x"))
      |> assert_has(css("#s-flag", text: "true"))
      |> assert_has(css("#s-min", text: "3"))
    end
  end
end
