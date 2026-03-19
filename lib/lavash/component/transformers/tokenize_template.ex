defmodule Lavash.Component.Transformers.TokenizeTemplate do
  @moduledoc """
  Tokenizes the template source string into HTML tokens.

  Runs the full EEx + HTML tokenization pipeline via `TagEngine.tokenize`
  (which drives `EEx.compile_string` in tokenize-only mode). This handles
  both `{expr}` and `<%= %>` syntax in a single pass.

  Persists:
  - `:lavash_template_tokens` — finalized HTML + expression token list
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
        dsl_state = Transformer.persist(dsl_state, :lavash_template_source, template_source)

        case safe_tokenize(template_source, sigil_line, env) do
          {:ok, tokens} ->
            dsl_state = Transformer.persist(dsl_state, :lavash_template_tokens, tokens)
            {:ok, dsl_state}

          :error ->
            {:ok, dsl_state}
        end
      end
    end
  end

  defp safe_tokenize(source, sigil_line, env) do
    opts = [
      file: env.file,
      line: (sigil_line || 0) + 1,
      caller: env,
      tag_handler: Phoenix.LiveView.HTMLEngine
    ]

    {:ok, Lavash.TagEngine.tokenize(source, opts)}
  rescue
    _ -> :error
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
