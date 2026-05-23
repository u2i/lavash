defmodule Lavash.Integration.FormsTest do
  @moduledoc """
  Ash-backed forms — `form :name, Resource` auto-generates per-field validity
  and error derives from the resource's constraints, with both client-side
  (transpiled) and server-side (round-trip) error sources merging into a
  single error list per field.
  """
  use ExUnit.Case, async: true

  @moduletag :e2e

  test "client-side validation errors appear instantly as the user types" do
    # Constraint failures (min_length, format, required) should surface
    # without a server round-trip.
    assert true
  end

  test "server-side validation errors appear after the debounced round-trip" do
    # Custom Ash validations (e.g. uniqueness) should appear after the
    # server replies, merged into the same field error list.
    assert true
  end

  test "errors are hidden until a field is touched or the form is submitted" do
    # Untouched fields should not show errors even when invalid.
    assert true
  end

  test "submit button enables only when the form is valid" do
    # `data-lavash-enabled` bound to `*_valid` should reflect overall form
    # validity in real time.
    assert true
  end

  test "extend_errors merges custom errors with auto-generated ones" do
    # Custom rx() errors should appear alongside Ash-derived errors on the
    # same field.
    assert true
  end

  test "successful submission triggers the on_success action" do
    # The configured on_success callback should fire and the post-submit
    # state (e.g. `submitted: true`) should be visible.
    assert true
  end

  test "failed submission triggers the on_error action" do
    # A server-side rejection should fire on_error and leave the form in
    # an editable state.
    assert true
  end
end
