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
      {loading_source, loading_line} = resolve_loading_source_and_line(lavash_renders)

      if is_nil(template_source) do
        {:ok, dsl_state}
      else
        dsl_state =
          dsl_state
          |> Transformer.persist(:lavash_template_source, template_source)
          |> persist_tokens(:lavash_template_tokens, template_source, sigil_line, env)
          |> tokenize_loading(loading_source, loading_line, env)

        {:ok, dsl_state}
      end
    end
  end

  # Tokenize the overlay loading template (from `template_loading do ~H end`)
  # into its own slot so the modal/flyover render generators can compile it
  # through the same token pipeline as the main render.
  defp tokenize_loading(dsl_state, nil, _line, _env), do: dsl_state

  defp tokenize_loading(dsl_state, loading_source, loading_line, env) do
    dsl_state
    |> Transformer.persist(:lavash_loading_source, loading_source)
    |> persist_tokens(:lavash_loading_tokens, loading_source, loading_line, env)
  end

  defp persist_tokens(dsl_state, key, source, sigil_line, env) do
    case safe_tokenize(source, sigil_line, env) do
      {:ok, tokens} -> Transformer.persist(dsl_state, key, tokens)
      :error -> dsl_state
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
    resolve_render_source(lavash_renders, :__render_fn__)
  end

  defp resolve_loading_source_and_line(lavash_renders) do
    resolve_render_source(lavash_renders, :__loading_fn__)
  end

  defp resolve_render_source(lavash_renders, key) do
    renders_map = Map.new(lavash_renders)

    case Map.get(renders_map, key) do
      nil -> {nil, nil}
      stored -> extract_source_and_line(stored)
    end
  end

  # `template do ~H"..." end` / `template_loading do ~H"..." end` register the
  # source as a tagged tuple on `@__lavash_renders__`.
  defp extract_source_and_line({:__lavash_template_source__, source, line})
       when is_binary(source) do
    {source, line}
  end

  defp extract_source_and_line(_), do: {nil, nil}
end
