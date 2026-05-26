defmodule Lavash.Template.Walker do
  @moduledoc """
  Shared tree-walker for HEEx token transformers.

  The LV 1.2 parser produces a tree of:

    * `{:block, type, name, attrs, children, open_meta, close_meta}`
      where `type` is `:tag` | `:local_component` | `:remote_component` | `:slot`
    * `{:self_close, type, name, attrs, meta}` — void/self-closing tags
    * `{:body_expr, code, meta}` — `{...}` inline expression
    * `{:eex, code, meta}` — `<%= ... %>` expression
    * `{:eex_block, code, clauses, meta}` — `<%= if x do %>...<% end %>`
      where each clause is `{children, end_code, meta}`
    * `{:text, content, meta}`
    * `{:eex_comment, content, meta}`

  Every sub-transformer that wants to walk this tree needs the same
  boilerplate: dispatch on the kind of node, recurse into children
  for blocks, recurse into each clause for `eex_block`, leave
  leaves alone. This module factors that out behind two callbacks.

  ## Callbacks

      walk(nodes, opts)

  where `opts` is a keyword list:

    * `:node_callback` — `(node, parent, metadata) -> [node]`.
      Receives the whole node, the parent context, and the
      threaded metadata. Returns a list (usually one element,
      sometimes more when a node expands). If omitted, defaults
      to `[node]`.

    * `:attrs_callback` — `(name, attrs, meta, metadata) ->
      attrs`. Receives the tag name + attrs list + opening-tag
      meta + threaded metadata. Returns the new attrs. The walker
      stitches the result back into the node. Use this when you
      want to inject attributes but don't need to rewrite node
      structure.

    * `:metadata` — opaque user data threaded through every
      callback. Sub-transformers stash their config here.

  ## What the walker does for you

    * Recurse into children of `:block` nodes.
    * Recurse into each clause's children for `:eex_block` nodes.
    * Track the parent node ({:tag, name, attrs} for the nearest
      enclosing block) so `node_callback` can make
      context-dependent decisions.
    * Leave leaves (`:text`, `:eex`, `:eex_comment`, unknown) alone
      unless `node_callback` rewrites them.

  ## Parent shape

  The `parent` passed to `node_callback` is `nil` at the top
  level, or `{:tag, name, attrs}` describing the immediately
  enclosing block node. This is sparse on purpose — most callers
  only care about the parent's tag name + attrs (e.g. "am I inside
  a `<textarea>`?", "is my parent already a display-wrapper?").
  """

  @doc """
  Walks `nodes` applying the configured callbacks.

  Returns the transformed node list.
  """
  def walk(nodes, opts) when is_list(nodes) do
    node_callback = Keyword.get(opts, :node_callback, &default_node_callback/3)
    attrs_callback = Keyword.get(opts, :attrs_callback, &default_attrs_callback/4)
    metadata = Keyword.get(opts, :metadata, %{})

    walk_nodes(
      nodes,
      %{
        node_callback: node_callback,
        attrs_callback: attrs_callback,
        metadata: metadata
      },
      _parent = nil
    )
  end

  defp default_node_callback(node, _parent, _metadata), do: [node]
  defp default_attrs_callback(_name, attrs, _meta, _metadata), do: attrs

  defp walk_nodes(nodes, ctx, parent) do
    Enum.flat_map(nodes, &walk_node(&1, ctx, parent))
  end

  # --- block nodes ---

  defp walk_node({:block, :tag, name, attrs, children, open_meta, close_meta}, ctx, _parent) do
    new_attrs = ctx.attrs_callback.(name, attrs, open_meta, ctx.metadata)
    new_children = walk_nodes(children, ctx, {:tag, name, new_attrs})
    node = {:block, :tag, name, new_attrs, new_children, open_meta, close_meta}
    ctx.node_callback.(node, _parent = nil, ctx.metadata)
  end

  defp walk_node(
         {:block, comp_type, name, attrs, children, open_meta, close_meta},
         ctx,
         parent
       )
       when comp_type in [:local_component, :remote_component] do
    new_children = walk_nodes(children, ctx, _parent = nil)
    node = {:block, comp_type, name, attrs, new_children, open_meta, close_meta}
    ctx.node_callback.(node, parent, ctx.metadata)
  end

  defp walk_node({:block, :slot, name, attrs, children, open_meta, close_meta}, ctx, parent) do
    new_children = walk_nodes(children, ctx, _parent = nil)
    node = {:block, :slot, name, attrs, new_children, open_meta, close_meta}
    ctx.node_callback.(node, parent, ctx.metadata)
  end

  # --- self_close nodes ---

  defp walk_node({:self_close, :tag, name, attrs, meta}, ctx, parent) do
    new_attrs = ctx.attrs_callback.(name, attrs, meta, ctx.metadata)
    ctx.node_callback.({:self_close, :tag, name, new_attrs, meta}, parent, ctx.metadata)
  end

  defp walk_node({:self_close, comp_type, _name, _attrs, _meta} = node, ctx, parent)
       when comp_type in [:local_component, :remote_component, :slot] do
    ctx.node_callback.(node, parent, ctx.metadata)
  end

  # --- expression nodes ---

  defp walk_node({:body_expr, _expr, _meta} = node, ctx, parent) do
    ctx.node_callback.(node, parent, ctx.metadata)
  end

  defp walk_node({:eex, _code, _meta} = node, ctx, parent) do
    ctx.node_callback.(node, parent, ctx.metadata)
  end

  defp walk_node({:eex_block, code, clauses, meta}, ctx, parent) do
    new_clauses =
      Enum.map(clauses, fn {clause_nodes, end_code, clause_meta} ->
        {walk_nodes(clause_nodes, ctx, _parent = nil), end_code, clause_meta}
      end)

    ctx.node_callback.({:eex_block, code, new_clauses, meta}, parent, ctx.metadata)
  end

  # --- catch-all (`:text`, `:eex_comment`, anything we don't recognize) ---

  defp walk_node(node, ctx, parent) do
    ctx.node_callback.(node, parent, ctx.metadata)
  end
end
