defmodule Lavash.Integration.UrlStateTest do
  @moduledoc """
  URL-backed state — same contract whether the field is declared via the DSL
  (`state :count, from: :url`) or wired by hand in `handle_params`. Both
  paths should hydrate from the URL on mount and reflect mutations in the
  rendered DOM.
  """
  use Lavash.IntegrationCase, async: false

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
end
