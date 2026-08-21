defmodule Lavash.Form.Validation do
  @moduledoc """
  Shared runtime helpers referenced by the generated constraint-check
  expressions (`Lavash.Form.ConstraintTranspiler.field_checks/3`).

  These run on BOTH sides of the wire: the server evaluates the
  Elixir directly; the client runs the transpiled JS equivalent the
  `Lavash.Optimistic.Transpiler` maps for each function. Keeping the
  semantic in one named function (with one JS mapping) is what makes
  client/server drift structurally impossible for integer parsing —
  previously the server required a full `Integer.parse` match while
  the client silently `parseInt`-ed to `NaN` (#125).
  """

  @doc """
  Strictly parses a form value as an integer: the whole trimmed
  string must be an integer, otherwise `nil`.

  JS equivalent (see the transpiler mapping): trimmed full-string
  regex check, then `parseInt`.
  """
  def parse_int(value) do
    case Integer.parse(String.trim(to_string(value || ""))) do
      {n, ""} -> n
      _ -> nil
    end
  end
end
