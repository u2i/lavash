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
  Converts a LV 1.2 node tree (or `%Parser{}`) into lavash's internal
  `:element` tree shape:

  - `{:element, tag, attrs, children, meta}` for HTML elements
  - `{:text, content}` for text nodes
  - `{:expr, code, meta}` for Elixir expressions

  Components and slots are skipped by default (they aren't consumed by
  layer-1 analysis). Pass `descend_components: true` to instead splice
  their children into the tree transparently — used by the optimistic
  template analysis so `:if`/`:for` subtrees inside component slots
  (e.g. a select inside `<.form>`) are still discoverable. The
  component boundary itself is never emitted; only the host-owned tags
  within its slots are.
  """
  def parse(input, opts \\ [])

  def parse(%Parser{nodes: nodes}, opts), do: parse(nodes, opts)

  def parse(nodes, opts) when is_list(nodes) do
    descend = Keyword.get(opts, :descend_components, false)
    Enum.flat_map(nodes, &node_to_element(&1, descend))
  end

  defp node_to_element({:block, :tag, name, attrs, children, open_meta, _close_meta}, descend) do
    [
      {:element, name, parse_attrs(attrs), parse(children, descend_components: descend),
       open_meta}
    ]
  end

  defp node_to_element({:self_close, :tag, name, attrs, meta}, _descend) do
    [{:element, name, parse_attrs(attrs), [], meta}]
  end

  defp node_to_element({:text, content, _meta}, _descend) do
    [{:text, content}]
  end

  defp node_to_element({:body_expr, code, meta}, _descend) do
    [{:expr, code, meta}]
  end

  defp node_to_element({:eex, code, meta}, _descend) do
    [{:expr, code, meta}]
  end

  defp node_to_element({:eex_block, _code, clauses, _meta}, descend) do
    Enum.flat_map(clauses, fn {clause_nodes, _end_code, _meta} ->
      parse(clause_nodes, descend_components: descend)
    end)
  end

  # `<.link>` is not opaque to the client half: it renders to a plain
  # anchor whose clicks LiveView's own client JS intercepts by
  # delegation (data-phx-link). Rewriting it to that anchor keeps links
  # inside optimistic subtrees rendered — and navigable — when the
  # client re-renders the subtree; flattened like other components, the
  # anchor would vanish until server truth repaints. Only literal
  # string targets and GET semantics are rewritable; anything else
  # falls back to the generic component handling below.
  defp node_to_element(
         {:block, :local_component, "link", attrs, children, open_meta, _close_meta} = node,
         descend
       ) do
    case link_anchor_attrs(parse_attrs(attrs)) do
      {:ok, anchor_attrs} ->
        [
          {:element, "a", anchor_attrs, parse(children, descend_components: descend), open_meta}
        ]

      :skip ->
        generic_component_to_element(node, descend)
    end
  end

  # Component/slot blocks: transparent descent when requested — their slot
  # children are host-owned markup that downstream analysis may care about.
  defp node_to_element(
         {:block, comp_type, _name, _attrs, _children, _open_meta, _close_meta} = node,
         descend
       )
       when comp_type in [:local_component, :remote_component, :slot] do
    generic_component_to_element(node, descend)
  end

  # Components, slots, eex_comment etc. are not interesting to downstream
  # consumers (AnalyzeTemplate looks at HTML tags and bare exprs).
  defp node_to_element(_node, _descend), do: []

  defp generic_component_to_element(
         {:block, _comp_type, _name, _attrs, children, _open_meta, _close_meta},
         true
       ) do
    parse(children, descend_components: true)
  end

  defp generic_component_to_element(_node, false), do: []

  # Maps `<.link>` attrs to the anchor Phoenix.Component.link/1 renders:
  # navigate → data-phx-link="redirect", patch → "patch", both with
  # data-phx-link-state push/replace; bare href passes through. Returns
  # :skip (→ generic component handling) for expr-valued targets,
  # non-GET methods, or no target at all.
  defp link_anchor_attrs(attrs) do
    method_ok? =
      case Enum.find(attrs, &match?({"method", _}, &1)) do
        nil -> true
        {"method", {:string, "get"}} -> true
        _ -> false
      end

    state =
      if Enum.any?(attrs, &match?({"replace", {:boolean, true}}, &1)), do: "replace", else: "push"

    passthrough =
      Enum.reject(attrs, fn {name, _} -> name in ~w(navigate patch href replace method) end)

    target = fn name ->
      case Enum.find(attrs, &match?({^name, {:string, _}}, &1)) do
        {^name, {:string, to}} -> to
        _ -> nil
      end
    end

    cond do
      not method_ok? ->
        :skip

      to = target.("navigate") ->
        {:ok,
         [
           {"href", {:string, to}},
           {"data-phx-link", {:string, "redirect"}},
           {"data-phx-link-state", {:string, state}} | passthrough
         ]}

      to = target.("patch") ->
        {:ok,
         [
           {"href", {:string, to}},
           {"data-phx-link", {:string, "patch"}},
           {"data-phx-link-state", {:string, state}} | passthrough
         ]}

      to = target.("href") ->
        {:ok, [{"href", {:string, to}} | passthrough]}

      true ->
        :skip
    end
  end

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
