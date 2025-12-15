defmodule Lavash.Derived.Form do
  @moduledoc """
  A declarative form definition in the derived section.

  Automatically creates an Ash form from a loaded record (or new if nil).
  """

  defstruct [
    :name,
    :resource,
    :load,
    :create,
    :update,
    :params,
    __spark_metadata__: nil
  ]
end
