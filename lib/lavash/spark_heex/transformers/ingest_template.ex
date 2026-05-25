defmodule Lavash.SparkHeex.Transformers.IngestTemplate do
  @moduledoc """
  Reads the `@__lavash_heex_template__` module attribute (set by the
  `template` macro) and persists it into the DSL state so subsequent
  transformers can inspect it.
  """
  use Spark.Dsl.Transformer

  def transform(dsl_state) do
    module = Spark.Dsl.Transformer.get_persisted(dsl_state, :module)

    case Module.get_attribute(module, :__lavash_heex_template__) do
      nil ->
        {:ok, dsl_state}

      {source, line} ->
        {:ok, Spark.Dsl.Transformer.persist(dsl_state, :heex_template, {source, line})}
    end
  end
end
