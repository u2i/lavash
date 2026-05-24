defmodule Lavash.Integration.ArraysAndKeyedTest do
  @moduledoc """
  Array state mutations — appending, removing, deriving from list state.
  """
  use Lavash.IntegrationCase, async: false

  test "appending adds a DOM node for the new item", %{session: session} do
    session
    |> visit("/arrays")
    |> assert_has(css("#item-a"))
    |> assert_has(css("#item-b"))
    |> refute_has_item("c")
    |> click(css("#add-c"))
    |> assert_has(css("#item-c"))
  end

  test "removing drops the matching DOM node", %{session: session} do
    session
    |> visit("/arrays")
    |> assert_has(css("#item-a"))
    |> click(css("#remove-a"))
    |> refute_has_item("a")
    |> assert_has(css("#item-b"))
  end

  test "clearing removes all items", %{session: session} do
    session
    |> visit("/arrays")
    |> click(css("#clear"))
    |> assert_has(css("#count", text: "0"))
    |> assert_has(css("#joined", text: ""))
  end

  test "calculations on length stay in sync after structural changes", %{session: session} do
    session
    |> visit("/arrays")
    |> assert_has(css("#count", text: "2"))
    |> click(css("#add-c"))
    |> assert_has(css("#count", text: "3"))
    |> click(css("#remove-a"))
    |> assert_has(css("#count", text: "2"))
    |> click(css("#clear"))
    |> assert_has(css("#count", text: "0"))
  end

  test "calculations on derived strings reflect array mutations", %{session: session} do
    session
    |> visit("/arrays")
    |> assert_has(css("#joined", text: "a,b"))
    |> click(css("#add-c"))
    |> assert_has(css("#joined", text: "a,b,c"))
    |> click(css("#remove-a"))
    |> assert_has(css("#joined", text: "b,c"))
  end

  defp refute_has_item(session, name) do
    refute Wallabidi.Browser.has?(session, Wallabidi.Query.css("#item-#{name}"))
    session
  end
end
