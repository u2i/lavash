defmodule Lavash.TagEngine do
  @moduledoc """
  Thin wrapper around `Phoenix.LiveView.TagEngine.{Parser, Compiler}`.

  Previously this module was a copy-paste fork of `Phoenix.LiveView.TagEngine`
  to insert a `:token_transformer` hook between tokenization and AST emission.
  In LV 1.2 the tag engine was split into a `Parser` (produces a node tree)
  and a `Compiler` (consumes the tree). That gives us a clean seam: tokenize
  once, walk/mutate the tree via a transformer, then compile.

  ## Public API (unchanged for callers)

    * `tokenize(source, opts)` — parses source to a `%Parser{}` (nodes tree)
    * `compile_from_tokens(parsed, opts)` — applies the optional
      `:token_transformer` and compiles to AST

  Options understood by `compile_from_tokens/2`:
    * `:token_transformer` — module implementing `Lavash.TokenTransformer`
      (the transformer's `transform/2` now receives the node tree, not a
      flat token list)
    * `:lavash_metadata` — opaque metadata passed to the transformer
    * everything else is forwarded to `Phoenix.LiveView.TagEngine.Compiler`
  """

  alias Phoenix.LiveView.TagEngine.{Parser, Compiler}

  @doc """
  Parses `source` into a `%Parser{}` (a node tree, suitable as input to
  `compile_from_tokens/2`).

  Raises if parsing fails.
  """
  def tokenize(source, opts) do
    opts =
      opts
      |> Keyword.put_new(:tag_handler, Phoenix.LiveView.HTMLEngine)

    case Parser.parse(source, opts) do
      {:ok, %Parser{} = parsed} ->
        parsed

      {:error, line, column, message} ->
        file = Keyword.get(opts, :file, "nofile")

        raise Phoenix.LiveView.TagEngine.Tokenizer.ParseError,
          line: line,
          column: column,
          file: file,
          description: message
    end
  end

  @doc """
  Compiles a parsed node tree into Elixir AST.

  Accepts the `%Parser{}` returned by `tokenize/2`. If a `:token_transformer`
  module is supplied in `opts`, its `transform/2` is invoked on the node
  tree before compilation.
  """
  def compile_from_tokens(%Parser{} = parsed, opts) do
    parsed =
      case Keyword.get(opts, :token_transformer) do
        nil ->
          parsed

        transformer ->
          state = %{
            file: Keyword.get(opts, :file, "nofile"),
            caller: Keyword.get(opts, :caller),
            source: Keyword.get(opts, :source, ""),
            tag_handler: Keyword.get(opts, :tag_handler, Phoenix.LiveView.HTMLEngine),
            lavash_metadata: Keyword.get(opts, :lavash_metadata)
          }

          %{parsed | nodes: transformer.transform(parsed.nodes, state)}
      end

    compile_opts =
      opts
      |> Keyword.drop([:token_transformer, :lavash_metadata])
      |> Keyword.put_new(:tag_handler, Phoenix.LiveView.HTMLEngine)
      |> Keyword.put_new(:source, "")

    Compiler.compile(parsed, compile_opts)
  end
end
