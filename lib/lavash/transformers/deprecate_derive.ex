defmodule Lavash.Transformers.DeprecateDerive do
  @moduledoc """
  Transformer that emits a deprecation warning when `derive` is used.

  The `derive` DSL is deprecated in favor of `calculate` with `rx()`.

  ## Migration

  Before:
      derive :foo do
        argument :bar, state(:bar)
        run fn %{bar: bar}, _ -> transform(bar) end
      end

  After:
      calculate :foo, rx(transform(@bar)), optimistic: false
  """

  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  # Run early so warning appears during compilation
  def after?(_), do: false
  def before?(_), do: false

  def transform(dsl_state) do
    derives = Transformer.get_entities(dsl_state, [:derives]) || []

    if derives != [] do
      module = Transformer.get_persisted(dsl_state, :module)
      derive_names = Enum.map(derives, & &1.name) |> Enum.join(", ")

      IO.warn("""
      [Lavash] `derive` is deprecated in favor of `calculate` with `rx()`.

      Found #{length(derives)} derive(s) in #{inspect(module)}: #{derive_names}

      Migration example:
        # Before
        derive :foo do
          argument :bar, state(:bar)
          run fn %{bar: bar}, _ -> transform(bar) end
        end

        # After
        calculate :foo, rx(transform(@bar)), optimistic: false
      """)
    end

    {:ok, dsl_state}
  end
end
