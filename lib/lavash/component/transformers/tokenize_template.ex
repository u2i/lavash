defmodule Lavash.Component.Transformers.TokenizeTemplate do
  @moduledoc """
  Tokenizes the component template source string into HTML tokens.

  Reads the raw template from the escaped `~L` sigil AST in `@__lavash_renders__`,
  tokenizes it once with file-absolute line numbers, and persists the tokens
  to dsl_state for downstream transformers.

  Persists:
  - `:lavash_template_tokens` — finalized HTML token list
  - `:lavash_template_source` — raw template source string
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  def after?(Lavash.Optimistic.Transformers.ExpandAnimatedStates), do: true
  def after?(Lavash.Transformers.ExpandFields), do: true
  def after?(_), do: false

  def before?(Lavash.Component.Transformers.AnalyzeTemplate), do: true
  def before?(Lavash.Optimistic.Transformers.ExtractColocatedJs), do: true
  def before?(_), do: false

  def transform(dsl_state) do
    env = Transformer.get_persisted(dsl_state, :env)

    if is_nil(env) do
      {:ok, dsl_state}
    else
      lavash_renders = Module.get_attribute(env.module, :__lavash_renders__) || []
      {template_source, sigil_line} = resolve_template_source_and_line(lavash_renders)

      if is_nil(template_source) do
        {:ok, dsl_state}
      else
        tokens = Lavash.Template.tokenize(template_source,
          line: (sigil_line || 0) + 1,
          file: env.file
        )

        dsl_state =
          dsl_state
          |> Transformer.persist(:lavash_template_tokens, tokens)
          |> Transformer.persist(:lavash_template_source, template_source)

        {:ok, dsl_state}
      end
    end
  end

  # ============================================
  # Template source extraction from escaped AST
  # ============================================

  defp resolve_template_source_and_line(lavash_renders) do
    renders_map = Map.new(lavash_renders)

    case Map.get(renders_map, :__render_fn__) do
      nil -> {nil, nil}
      escaped_fn -> extract_source_and_line(escaped_fn)
    end
  end

  defp extract_source_and_line({:fn, _, [{:->, _, [[_], body]}]}), do: extract_compiled_source_and_line(body)
  defp extract_source_and_line(_), do: {nil, nil}

  defp extract_compiled_source_and_line({:sigil_L, meta, [{:<<>>, _, [source]}, _]}) when is_binary(source) do
    {source, Keyword.get(meta, :line)}
  end
  defp extract_compiled_source_and_line({:%, _, [{:__aliases__, _, [:Lavash, :Template, :Compiled]}, {:%{}, _, fields}]}) do
    {Keyword.get(fields, :source), nil}
  end
  defp extract_compiled_source_and_line({:__block__, _, [inner]}), do: extract_compiled_source_and_line(inner)
  defp extract_compiled_source_and_line({:quote, _, [[do: ast]]}), do: extract_compiled_source_and_line(ast)
  defp extract_compiled_source_and_line(_), do: {nil, nil}
end
