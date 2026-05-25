defmodule Lavash.Template do
  @moduledoc """
  Utilities for parsing HEEx templates into a small `:element` tree.

  Provides `tokenize/2` (parses to the new LV 1.2 Parser node tree) and
  `parse/1` (converts that tree into a simpler `{:element, tag, attrs,
  children, meta}` form that the rest of lavash's compile-time analysis
  pipeline consumes).
  """

  alias Phoenix.LiveView.TagEngine.Parser

  @doc """
  Parses HEEx `source` to the LV 1.2 node tree (`%Parser{}` or just the
  `nodes` list, depending on `:return`).

  Options:
    * `:line` - starting line number (default 1)
    * `:file` - source file path for error messages (default "nofile")
    * `:indentation` - indentation level (default 0)
    * `:return` - `:nodes` (default) returns the bare node list,
      `:parser` returns the full `%Parser{}` struct
  """
  def tokenize(source, opts \\ []) do
    parser_opts =
      opts
      |> Keyword.take([:line, :file, :indentation, :caller])
      |> Keyword.put_new(:tag_handler, Phoenix.LiveView.HTMLEngine)

    case Parser.parse(source, parser_opts) do
      {:ok, %Parser{} = parsed} ->
        case Keyword.get(opts, :return, :nodes) do
          :parser -> parsed
          :nodes -> parsed.nodes
        end

      {:error, line, column, message} ->
        raise Phoenix.LiveView.TagEngine.Tokenizer.ParseError,
          line: line,
          column: column,
          file: Keyword.get(opts, :file, "nofile"),
          description: message
    end
  end

  @doc """
  Converts a LV 1.2 node tree (or `%Parser{}`) into the legacy `:element`
  tree shape:

  - `{:element, tag, attrs, children, meta}` for HTML elements
  - `{:text, content}` for text nodes
  - `{:expr, code, meta}` for Elixir expressions

  Components and slots are skipped (they aren't consumed downstream).
  """
  def parse(%Parser{nodes: nodes}), do: parse(nodes)

  def parse(nodes) when is_list(nodes) do
    Enum.flat_map(nodes, &node_to_element/1)
  end

  defp node_to_element({:block, :tag, name, attrs, children, open_meta, _close_meta}) do
    [{:element, name, parse_attrs(attrs), parse(children), open_meta}]
  end

  defp node_to_element({:self_close, :tag, name, attrs, meta}) do
    [{:element, name, parse_attrs(attrs), [], meta}]
  end

  defp node_to_element({:text, content, _meta}) do
    [{:text, content}]
  end

  defp node_to_element({:body_expr, code, meta}) do
    [{:expr, code, meta}]
  end

  defp node_to_element({:eex, code, meta}) do
    [{:expr, code, meta}]
  end

  defp node_to_element({:eex_block, _code, clauses, _meta}) do
    Enum.flat_map(clauses, fn {clause_nodes, _end_code, _meta} -> parse(clause_nodes) end)
  end

  # Components, slots, eex_comment etc. are not interesting to downstream
  # consumers (AnalyzeTemplate looks at HTML tags and bare exprs).
  defp node_to_element(_node), do: []

  defp parse_attrs(attrs) do
    Enum.flat_map(attrs, fn
      {:root, _value, _attr_meta} ->
        []

      {name, {:expr, code, expr_meta}, _attr_meta} ->
        [{name, {:expr, code, expr_meta}}]

      {name, {:string, value, _str_meta}, _attr_meta} ->
        [{name, {:string, value}}]

      {name, nil, _attr_meta} ->
        [{name, {:boolean, true}}]

      _other ->
        []
    end)
  end
end
