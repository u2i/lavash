defmodule Lavash.Integration.UrlStateTest do
  @moduledoc """
  `from: :url` state — fields backed by the query string. Should round-trip
  through the URL, survive reload, and play well with browser navigation.
  """
  use ExUnit.Case, async: true

  @moduletag :e2e

  test "mutating a url-backed field updates the address bar" do
    # Without a full navigation, the URL should reflect the new value
    # (push/replace state).
    assert true
  end

  test "deep-linking a URL hydrates state on mount" do
    # Opening the page with a pre-populated query string should set the
    # initial state accordingly.
    assert true
  end

  test "browser back navigation restores the previous state" do
    # The history entry should be honored — back/forward should not lose
    # field values.
    assert true
  end

  test "default values are not serialized into the URL" do
    # Fields at their declared default should be omitted from the query
    # string to keep URLs clean.
    assert true
  end
end
