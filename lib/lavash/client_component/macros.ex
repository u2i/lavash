defmodule Lavash.ClientComponent.Macros do
  @moduledoc """
  Deprecated: Use Lavash.Optimistic.Macros instead.

  This module re-exports the shared macros for backwards compatibility.
  New code should import Lavash.Optimistic.Macros directly.
  """

  # Re-export the calculate macro from the shared module
  defmacro calculate(name, expr) do
    quote do
      require Lavash.Optimistic.Macros
      Lavash.Optimistic.Macros.calculate(unquote(name), unquote(expr))
    end
  end

  # Re-export the optimistic_action macro from the shared module
  defmacro optimistic_action(name, field, opts) do
    quote do
      require Lavash.Optimistic.Macros
      Lavash.Optimistic.Macros.optimistic_action(unquote(name), unquote(field), unquote(opts))
    end
  end
end
