defmodule Lavash.Optimistic.Strictness do
  @moduledoc """
  Policy for optimistic code that cannot fulfill its promise.

  `optimistic: true` (the default for calcs) is a stated intent that
  the code runs client-side. Code that can't — an untranspilable rx
  body, or a dependency that never exists in client state — fails the
  build by default, the way subtree derives always have.

  ## Escape hatch

      config :lavash, :untranspilable_optimistic, :warn

  restores the pre-#46 warn-and-demote behavior (the calc/set is
  excluded client-side and the server value flows via patches) as a
  transitional aid. The default is `:error`.
  """

  require Logger

  def mode do
    Application.get_env(:lavash, :untranspilable_optimistic, :error)
  end

  @doc """
  Reports a broken optimistic promise. Raises a `Spark.Error.DslError`
  in `:error` mode (the default); logs and returns `:demoted` in
  `:warn` mode so the caller can fall back to the old demote path.
  """
  def violation!(module, path, message) do
    case mode() do
      :warn ->
        Logger.warning("[lavash] #{inspect(module)}: #{message}")
        :demoted

      _ ->
        raise Spark.Error.DslError, module: module, path: path, message: message
    end
  end
end
