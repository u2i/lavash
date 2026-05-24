defmodule Lavash.Integration.FormsTest do
  @moduledoc """
  Ash-backed forms — `form :name, Resource do create ... end` auto-generates
  per-field validity, error lists, and submission via Ash.

  Fixture: test/support/magic/test_forms_fixture.ex defines Test.Magic.Forms.Signup with
  name (min_length 2, required) and age (min 18, required).

  These tests exercise the server-side validation path (errors arrive after
  phx-change round-trip). The client-side instant-validation path lives in a
  JS-only suite — it requires the LavashOptimistic hook loaded in the test
  layout, which we don't do yet.
  """
  use Lavash.IntegrationCase, async: false

  test "form mounts with empty params and not-submitted", %{session: session} do
    session
    |> visit("/magic/form")
    |> assert_has(css("#submitted", text: "false"))
    |> assert_has(css("#signup-name"))
    |> assert_has(css("#signup-age"))
  end

  test "name shorter than min_length produces an error after blur", %{session: session} do
    session
    |> visit("/magic/form")
    |> fill_in(css("#signup-name"), with: "x")

    # phx-change fires on blur via phx-change form-level binding. Wait for
    # the error span to populate.
    assert_has(session, css("#signup-name-errors"))
  end

  test "valid name passes the constraint check", %{session: session} do
    session
    |> visit("/magic/form")
    |> fill_in(css("#signup-name"), with: "Valid Name")
    |> assert_has(css("#signup-name"))
  end

  test "form_valid flips when all fields are valid", %{session: session} do
    session
    |> visit("/magic/form")
    |> fill_in(css("#signup-name"), with: "Alice")
    |> fill_in(css("#signup-age"), with: "30")
    |> assert_has(css("#signup-valid"))
  end

  test "submitting a valid form fires on_success", %{session: session} do
    session
    |> visit("/magic/form")
    |> fill_in(css("#signup-name"), with: "Alice")
    |> fill_in(css("#signup-age"), with: "30")
    |> click(css("#signup-submit"))
    |> assert_has(css("#submitted", text: "true"))
  end

  test "submitting an invalid form does not fire on_success", %{session: session} do
    session
    |> visit("/magic/form")
    |> fill_in(css("#signup-name"), with: "x")
    |> fill_in(css("#signup-age"), with: "10")
    |> click(css("#signup-submit"))
    |> assert_has(css("#submitted", text: "false"))
  end

  test "errors clear when input becomes valid", %{session: session} do
    session
    |> visit("/magic/form")
    |> fill_in(css("#signup-name"), with: "x")
    |> fill_in(css("#signup-name"), with: "Alice")
    |> assert_has(css("#signup-name"))
  end
end
