defmodule Lavash.SparkHeex.Transformers.ValidateTemplate do
  @moduledoc """
  Demonstrates the core spike value: the template is now a first-class DSL
  citizen, so we can cross-validate it against other DSL entities at DSL
  build time (i.e. inside the Spark transformer pipeline, not in a
  bolted-on post-compile pass).

  We extract `@field` references from the raw HEEx source and check that
  each one matches a declared `state :field`. Unknown references raise a
  Spark.Error.DslError pointed at the surrounding DSL.
  """
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer
  alias Spark.Error.DslError

  # Run after IngestTemplate, before CompileTemplate.
  def after?(Lavash.SparkHeex.Transformers.IngestTemplate), do: true
  def after?(_), do: false

  def before?(Lavash.SparkHeex.Transformers.CompileTemplate), do: true
  def before?(_), do: false

  def transform(dsl_state) do
    case Transformer.get_persisted(dsl_state, :heex_template) do
      nil ->
        {:ok, dsl_state}

      {source, _line} ->
        declared = declared_state_names(dsl_state)
        referenced = referenced_assigns(source)
        unknown = MapSet.difference(referenced, declared)

        if MapSet.size(unknown) == 0 do
          {:ok, dsl_state}
        else
          missing = unknown |> MapSet.to_list() |> Enum.sort()

          {:error,
           DslError.exception(
             module: Transformer.get_persisted(dsl_state, :module),
             path: [:template],
             message:
               "template references undeclared state field(s): " <>
                 Enum.map_join(missing, ", ", &"@#{&1}") <>
                 ". Declared fields: " <>
                 (declared |> MapSet.to_list() |> Enum.sort() |> Enum.map_join(", ", &"@#{&1}"))
           )}
        end
    end
  end

  defp declared_state_names(dsl_state) do
    dsl_state
    |> Transformer.get_entities([:states])
    |> Enum.map(& &1.name)
    |> MapSet.new()
  end

  # Cheap, deliberately naive scan: pull out `@identifier` occurrences from
  # the raw HEEx source. Good enough for the spike; a real implementation
  # would walk the tokenized HEEx AST so it skipped strings, comments, etc.
  defp referenced_assigns(source) do
    ~r/@([a-z_][a-zA-Z0-9_]*)/
    |> Regex.scan(source, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(&String.to_atom/1)
    |> MapSet.new()
  end
end
