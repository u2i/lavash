defmodule Lavash.Template do
  @moduledoc """
  Utilities for parsing HEEx templates into tree structures.

  Provides `tokenize/1` and `parse/1` for converting HEEx source into
  a tree of nodes that can be analyzed for subtree derive extraction
  and other compile-time transformations.
  """

  alias Phoenix.LiveView.Tokenizer

  @doc """
  Tokenizes HEEx source into a list of tokens.
  """
  def tokenize(source) do
    state = Tokenizer.init(0, "nofile", source, Phoenix.LiveView.HTMLEngine)

    case Tokenizer.tokenize(source, [line: 1, column: 1], [], {:text, :enabled}, state) do
      {tokens, _cont} ->
        Tokenizer.finalize(tokens, "nofile", {:text, :enabled}, source)
    end
  end

  @doc """
  Parses tokens into a tree structure.

  Each node is:
  - `{:element, tag, attrs, children, meta}` for HTML elements
  - `{:text, content}` for text nodes
  - `{:expr, code, meta}` for Elixir expressions
  """
  def parse(tokens) do
    {tree, []} = parse_children(tokens, [])
    tree
  end

  defp parse_children([], acc), do: {Enum.reverse(acc), []}

  defp parse_children([{:close, :tag, _name, _meta} | _rest] = tokens, acc) do
    {Enum.reverse(acc), tokens}
  end

  defp parse_children([{:tag, name, attrs, meta} | rest], acc) do
    case meta[:closing] do
      closing when closing in [:self, :void] ->
        node = {:element, name, parse_attrs(attrs), [], meta}
        parse_children(rest, [node | acc])

      _ ->
        {children, rest2} = parse_children(rest, [])

        rest3 =
          case rest2 do
            [{:close, :tag, ^name, _} | r] -> r
            _ -> rest2
          end

        node = {:element, name, parse_attrs(attrs), children, meta}
        parse_children(rest3, [node | acc])
    end
  end

  defp parse_children([{:text, content, _meta} | rest], acc) do
    parse_children(rest, [{:text, content} | acc])
  end

  defp parse_children([{:expr, code, meta} | rest], acc) do
    parse_children(rest, [{:expr, code, meta} | acc])
  end

  defp parse_children([{:body_expr, code, meta} | rest], acc) do
    parse_children(rest, [{:expr, code, meta} | acc])
  end

  defp parse_children([{:special_attr, type, name, value, meta} | rest], acc) do
    parse_children(rest, [{:special_attr, type, name, value, meta} | acc])
  end

  defp parse_children([_unknown | rest], acc) do
    parse_children(rest, acc)
  end

  defp parse_attrs(attrs) do
    Enum.map(attrs, fn
      {name, {:expr, code, expr_meta}, _attr_meta} ->
        {name, {:expr, code, expr_meta}}

      {name, {:string, value, _str_meta}, _attr_meta} ->
        {name, {:string, value}}

      {name, nil, _attr_meta} ->
        {name, {:boolean, true}}

      {name, {:expr, code, meta}} ->
        {name, {:expr, code, meta}}

      {name, {:string, value, _meta}} ->
        {name, {:string, value}}

      {name, nil} ->
        {name, {:boolean, true}}

      other ->
        other
    end)
  end
end
