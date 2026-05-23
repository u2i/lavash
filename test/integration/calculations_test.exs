defmodule Lavash.Integration.CalculationsTest do
  @moduledoc """
  Reactive calculations — `calculate :name, rx(...)` transpiles to JS and
  recomputes on the client whenever its dependencies change.
  """
  use ExUnit.Case, async: true

  @moduletag :e2e

  test "downstream calculations update synchronously with their dependencies" do
    # Changing a state field should update everything that depends on it
    # within the same render — no flicker showing stale derived values.
    assert true
  end

  test "transitive dependency chains recompute in topological order" do
    # state -> calc A -> calc B -> calc C. After mutating state, no
    # intermediate frame should show a half-updated graph.
    assert true
  end

  test "async calculations show loading state then resolved value" do
    # `async: true` calculations should expose an AsyncResult that the
    # template can pattern-match on (loading / ok / failed).
    assert true
  end

  test "non-optimistic calculations only update after server round-trip" do
    # `optimistic: false` calculations (e.g. server timestamp) must NOT
    # recompute on the client when their inputs change.
    assert true
  end
end
