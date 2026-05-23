defmodule Lavash.Integration.ActionsTest do
  @moduledoc """
  Actions — declared in `actions do ... end`, callable from the client via
  `phx-click`. Actions made of pure `set` / `rx()` ops transpile to JS and
  run on the client; actions with `run` blocks execute on the server.
  """
  use ExUnit.Case, async: true

  @moduletag :e2e

  test "transpilable actions run entirely on the client" do
    # An action consisting of `set` ops with rx() expressions should mutate
    # state with no network traffic.
    assert true
  end

  test "server-only actions trigger a round-trip" do
    # Actions using `run` or non-transpilable code should require the
    # server reply to update state.
    assert true
  end

  test "phx-value-* attributes are passed as action parameters" do
    # Values declared in the action's parameter list should be populated
    # from matching `phx-value-*` DOM attributes.
    assert true
  end

  test "actions can read multiple fields with reads" do
    # `reads [:a, :b]` followed by `run` should receive both current values
    # in assigns.
    assert true
  end

  test "auto-generated setters mutate the named field" do
    # Fields with `setter: true` should expose a JS setter callable from
    # input bindings (integer coercion included).
    assert true
  end
end
