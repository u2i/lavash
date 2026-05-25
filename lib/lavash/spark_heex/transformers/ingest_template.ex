defmodule Lavash.SparkHeex.Transformers.IngestTemplate do
  @moduledoc """
  Reads the `@__lavash_heex_template__` module attribute (set by the
  `template` macro) and persists it into the DSL state so subsequent
  transformers can inspect it.

  Also parses the HEEx source via `Phoenix.LiveView.TagEngine.Parser` and
  persists the resulting node tree as `:heex_tree`. Downstream transformers
  (`ValidateEvents`) walk that tree to validate phx-* event handler
  attributes against declared actions.

  In LV 1.2 the parser emits a nested tree of `:block` / `:self_close` /
  `:body_expr` / `:eex_block` / `:text` / `:eex_comment` nodes. See
  `Phoenix.LiveView.TagEngine.Parser` for the @type definitions.
  """
  use Spark.Dsl.Transformer

  alias Phoenix.LiveView.TagEngine.Parser
  alias Spark.Dsl.Transformer

  def transform(dsl_state) do
    module = Transformer.get_persisted(dsl_state, :module)

    case Module.get_attribute(module, :__lavash_heex_template__) do
      nil ->
        {:ok, dsl_state}

      {source, line} ->
        dsl_state =
          dsl_state
          |> Transformer.persist(:heex_template, {source, line})
          |> Transformer.persist(:heex_tree, parse(source, line))

        {:ok, dsl_state}
    end
  end

  defp parse(source, line) do
    opts = [
      tag_handler: Phoenix.LiveView.HTMLEngine,
      file: "nofile",
      line: line,
      strip_eex_comments: true
    ]

    case Parser.parse(source, opts) do
      {:ok, %Parser{nodes: nodes}} -> nodes
      _ -> []
    end
  rescue
    # Parse errors surface later in CompileTemplate; no-op here so
    # validators don't double-report.
    _ -> []
  end
end
