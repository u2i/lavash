defmodule Lavash.Component.JsGenerator do
  @moduledoc """
  Transpiles parsed HEEx template nodes to JavaScript template literal strings.

  Used by subtree derive extraction to generate small JS render functions
  for `:if`/`:for` subtrees over optimistic state.
  """

  @doc """
  Transpile a parsed element node to a JS template literal string.

  Takes a node from `Lavash.Template.parse/1` and returns a JS expression
  that produces the equivalent HTML. Used for subtree derives.
  """
  def subtree_to_js(node) do
    parts = node_to_js_parts(node, %{})
    Enum.join(parts, "")
  end

  defp tree_to_js_parts(nodes, ctx) when is_list(nodes) do
    Enum.flat_map(nodes, &node_to_js_parts(&1, ctx))
  end

  defp node_to_js_parts({:text, content}, _ctx) do
    escaped =
      content
      |> String.replace("\\", "\\\\")
      |> String.replace("`", "\\`")
      |> String.replace("${", "\\${")

    [escaped]
  end

  defp node_to_js_parts({:expr, code, _meta}, _ctx) do
    js_expr = Lavash.Rx.Transpiler.to_js(code)
    ["${#{js_expr}}"]
  end

  defp node_to_js_parts({:element, tag, attrs, children, meta}, ctx) do
    case find_special_attr(attrs, :for) do
      {:for, for_expr} ->
        {var, collection_js} = parse_for_to_js(for_expr)
        attrs_without_for = reject_special_attr(attrs, :for)
        new_ctx = Map.put(ctx, :loop_var, var)
        inner = render_element_wrapped(tag, attrs_without_for, children, meta, new_ctx)
        ["${#{collection_js}.map(#{var} => #{inner}).join('')}"]

      nil ->
        case find_special_attr(attrs, :if) do
          {:if, if_expr} ->
            condition_js = Lavash.Rx.Transpiler.to_js(if_expr)
            attrs_without_if = reject_special_attr(attrs, :if)
            inner = render_element_wrapped(tag, attrs_without_if, children, meta, ctx)
            ["${#{condition_js} ? #{inner} : ''}"]

          nil ->
            render_element_parts(tag, attrs, children, meta, ctx)
        end
    end
  end

  defp node_to_js_parts({:special_attr, _, _, _, _}, _ctx), do: []

  @void_elements ~w(area base br col embed hr img input link meta source track wbr)

  defp render_element_parts(tag, attrs, children, _meta, ctx) do
    attrs_js = render_attrs_to_js(attrs, ctx)

    if children == [] do
      if tag in @void_elements do
        ["<#{tag}#{attrs_js}>"]
      else
        ["<#{tag}#{attrs_js}></#{tag}>"]
      end
    else
      children_parts = tree_to_js_parts(children, ctx)
      ["<#{tag}#{attrs_js}>"] ++ children_parts ++ ["</#{tag}>"]
    end
  end

  defp render_element_wrapped(tag, attrs, children, _meta, ctx) do
    attrs_js = render_attrs_to_js(attrs, ctx)

    if children == [] do
      if tag in @void_elements do
        "`<#{tag}#{attrs_js}>`"
      else
        "`<#{tag}#{attrs_js}></#{tag}>`"
      end
    else
      children_parts = tree_to_js_parts(children, ctx)
      children_js = Enum.join(children_parts, "")
      "`<#{tag}#{attrs_js}>#{children_js}</#{tag}>`"
    end
  end

  defp render_attrs_to_js(attrs, ctx) do
    attrs
    |> Enum.reject(fn {name, _} -> String.starts_with?(name, ":") end)
    |> Enum.map(fn {name, value} -> render_attr_to_js(name, value, ctx) end)
    |> Enum.join("")
  end

  defp render_attr_to_js(name, {:string, value}, _ctx) do
    escaped =
      value
      |> String.replace("&", "&amp;")
      |> String.replace("\"", "&quot;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")

    " #{name}=\"#{escaped}\""
  end

  @boolean_attrs ~w(disabled checked readonly required hidden selected autofocus autoplay controls loop muted novalidate open)

  defp render_attr_to_js(name, {:expr, code, _}, _ctx) do
    js_expr = Lavash.Rx.Transpiler.to_js(code)

    if name in @boolean_attrs do
      " ${#{js_expr} ? '#{name}' : ''}"
    else
      " #{name}=\"${#{js_expr}}\""
    end
  end

  defp render_attr_to_js(name, {:boolean, true}, _ctx), do: " #{name}"
  defp render_attr_to_js(_name, {:boolean, false}, _ctx), do: ""
  defp render_attr_to_js(_name, _value, _ctx), do: ""

  defp find_special_attr(attrs, type) do
    key = ":#{type}"

    case Enum.find(attrs, fn {name, _} -> name == key end) do
      {^key, {:expr, code, _}} -> {type, code}
      _ -> nil
    end
  end

  defp reject_special_attr(attrs, type) do
    key = ":#{type}"
    Enum.reject(attrs, fn {name, _} -> name == key end)
  end

  defp parse_for_to_js(code) do
    case Code.string_to_quoted(code) do
      {:ok, {:<-, _, [{var, _, _}, collection]}} when is_atom(var) ->
        {to_string(var), Lavash.Rx.Transpiler.to_js(Macro.to_string(collection))}

      _ ->
        {"item", "[]"}
    end
  end
end
