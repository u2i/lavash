defmodule Lavash.Component.Transformers.TokenizeHtml do
  @moduledoc """
  Tokenizes EEx text chunks into HTML tokens.

  Reads EEx tokens from `:lavash_eex_tokens` (produced by `TokenizeEEx`),
  runs the Phoenix HTML tokenizer on each text chunk, and interleaves
  expression tokens to produce the combined HTML token list.

  Persists:
  - `:lavash_template_tokens` — finalized HTML + expression token list
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer
  alias Phoenix.LiveView.Tokenizer

  def after?(Lavash.Component.Transformers.TokenizeEEx), do: true
  def after?(_), do: false

  def before?(Lavash.Component.Transformers.AnalyzeTemplate), do: true
  def before?(Lavash.Optimistic.Transformers.ExtractColocatedJs), do: true
  def before?(_), do: false

  def transform(dsl_state) do
    eex_tokens = Transformer.get_persisted(dsl_state, :lavash_eex_tokens)
    source = Transformer.get_persisted(dsl_state, :lavash_template_source)
    env = Transformer.get_persisted(dsl_state, :env)

    if is_nil(eex_tokens) or is_nil(source) or is_nil(env) do
      {:ok, dsl_state}
    else
      case tokenize_html(eex_tokens, source, env.file) do
        {:ok, tokens} ->
          dsl_state = Transformer.persist(dsl_state, :lavash_template_tokens, tokens)
          {:ok, dsl_state}

        :error ->
          {:ok, dsl_state}
      end
    end
  end

  # ============================================
  # HTML tokenization from EEx token stream
  # ============================================

  defp tokenize_html(eex_tokens, source, file) do
    tokenizer_state = Tokenizer.init(0, file, source, Phoenix.LiveView.HTMLEngine)
    {html_tokens, cont} = process_eex_tokens(eex_tokens, [], {:text, :enabled}, tokenizer_state, file)
    tokens = Tokenizer.finalize(html_tokens, file, cont, source)
    {:ok, tokens}
  rescue
    _ -> :error
  end

  defp process_eex_tokens([], html_tokens, cont, _state, _file) do
    {html_tokens, cont}
  end

  defp process_eex_tokens([{:text, chars, meta} | rest], html_tokens, cont, state, file) do
    text = IO.chardata_to_string(chars)
    meta = [line: meta.line, column: meta.column]
    {html_tokens, cont} = Tokenizer.tokenize(text, meta, html_tokens, cont, state)
    process_eex_tokens(rest, html_tokens, cont, state, file)
  end

  defp process_eex_tokens([{type, mark, chars, meta} | rest], html_tokens, cont, state, file)
       when type in [:expr, :start_expr, :middle_expr, :end_expr] do
    mark_str = IO.chardata_to_string(mark)
    options = [file: file, line: meta.line, column: meta.column + 2 + length(mark)]
    expr = Code.string_to_quoted!(chars, options)
    html_tokens = [{:expr, mark_str, expr} | html_tokens]
    process_eex_tokens(rest, html_tokens, cont, state, file)
  end

  defp process_eex_tokens([{:comment, _chars, _meta} | rest], html_tokens, cont, state, file) do
    process_eex_tokens(rest, html_tokens, cont, state, file)
  end

  defp process_eex_tokens([{:eof, _meta} | _rest], html_tokens, cont, _state, _file) do
    {html_tokens, cont}
  end
end
