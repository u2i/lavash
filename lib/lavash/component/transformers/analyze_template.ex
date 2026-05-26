defmodule Lavash.Component.Transformers.AnalyzeTemplate do
  @moduledoc """
  Layer-1 template analysis: collects compile-time validation data
  from the already-parsed template tree.

  Reads `:lavash_template_tokens` (the parser tree produced by
  `TokenizeTemplate`) and walks it to extract:

    * `:lavash_template_phx_events` — every `phx-click`,
      `phx-submit`, `phx-mouseenter`, etc. occurrence (with
      static-string event names) grouped per node alongside the
      same node's `phx-value-*` attribute keys. `ValidateTemplate`
      cross-checks each event name against declared actions and
      each phx-value key against the actions' params.

    * `:lavash_template_assign_refs` — every `@name` reference
      anywhere an Elixir expression appears in HEEx (inline
      `{@x}`, attr `class={@x}`, `<%= @x %>`, `:if={@x}`, etc.).
      `ValidateTemplate` checks each against the declared
      state / props / slots / calculations / etc.

  ## What this transformer does NOT do

  Layer-4 (optimism) work — extracting subtree derives, attr
  derives, and injecting `data-lavash-html` attrs — lives in
  `Lavash.Optimistic.Transformers.AnalyzeOptimisticTemplate`, which
  runs after this transformer. Per `docs/ARCHITECTURE.md`
  punchlist item #4, the two were split so layer-1 consumers
  don't pay for layer-4 analysis.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  def after?(Lavash.Component.Transformers.TokenizeTemplate), do: true
  def after?(Lavash.Optimistic.Transformers.ExpandAnimatedStates), do: true
  def after?(Lavash.Transformers.ExpandFields), do: true
  def after?(_), do: false

  def before?(Lavash.Optimistic.Transformers.AnalyzeOptimisticTemplate), do: true
  def before?(Lavash.Optimistic.Transformers.ExtractColocatedJs), do: true
  def before?(_), do: false

  def transform(dsl_state) do
    parsed = Transformer.get_persisted(dsl_state, :lavash_template_tokens)

    if is_nil(parsed) do
      {:ok, dsl_state}
    else
      # Collect phx-event references so `ValidateTemplate` can
      # cross-check against declared actions.
      phx_events = collect_phx_events(parsed.nodes)
      dsl_state = Transformer.persist(dsl_state, :lavash_template_phx_events, phx_events)

      # Collect every `@name` reference for `ValidateTemplate` to
      # check against declared state / props / slots / etc.
      assign_refs = collect_assign_refs(parsed.nodes)
      dsl_state = Transformer.persist(dsl_state, :lavash_template_assign_refs, assign_refs)

      {:ok, dsl_state}
    end
  end

  # ============================================
  # phx-event extraction (for ValidateTemplate)
  # ============================================

  # The Phoenix event attributes that, when given a string value,
  # refer to a `handle_event/3` handler — i.e. a lavash
  # `action :name do ... end`. Dynamic values
  # (`phx-click={JS.dispatch(...)}` or `phx-click={@var}`) are
  # skipped: we can't know statically whether they resolve to a
  # server event name or a JS command.
  @phx_event_attrs ~w(phx-click phx-change phx-submit phx-blur phx-focus
                      phx-keydown phx-keyup phx-window-keydown phx-window-keyup
                      phx-mouseenter phx-mouseleave phx-mouseover phx-mouseout
                      phx-mousedown phx-mouseup
                      phx-viewport-top phx-viewport-bottom)

  defp collect_phx_events(nodes) do
    nodes
    |> walk_for_phx_events([])
    |> Enum.uniq()
  end

  defp walk_for_phx_events(nodes, acc) when is_list(nodes) do
    Enum.reduce(nodes, acc, &walk_node_for_phx_events/2)
  end

  defp walk_node_for_phx_events(
         {:block, :tag, _name, attrs, children, _open_meta, _close_meta},
         acc
       ) do
    acc = extract_attrs(attrs, acc)
    walk_for_phx_events(children, acc)
  end

  defp walk_node_for_phx_events({:self_close, :tag, _name, attrs, _meta}, acc) do
    extract_attrs(attrs, acc)
  end

  # Component nodes: don't extract from the component's own attrs
  # (they bind to props, not host event handlers), BUT recurse into
  # children — slots can contain host-owned tags with phx-click.
  defp walk_node_for_phx_events(
         {:block, comp_type, _name, _attrs, children, _open_meta, _close_meta},
         acc
       )
       when comp_type in [:local_component, :remote_component, :slot] do
    walk_for_phx_events(children, acc)
  end

  defp walk_node_for_phx_events({:self_close, _comp_type, _name, _attrs, _meta}, acc) do
    acc
  end

  defp walk_node_for_phx_events({:eex_block, _code, clauses, _meta}, acc) do
    Enum.reduce(clauses, acc, fn {children, _end_code, _meta}, acc ->
      walk_for_phx_events(children, acc)
    end)
  end

  defp walk_node_for_phx_events(_other, acc), do: acc

  # Emit one record per **node** that has any phx-event(s):
  #
  #   {events_list, phx_value_keys, node_meta}
  #
  # where `events_list` is `[{action_name, event_meta}, ...]`. The
  # phx-value-* set is shared across all phx-events on the node at
  # runtime, so we attach it per-node, not per-event.
  defp extract_attrs(attrs, acc) do
    {events, value_keys, node_meta} =
      Enum.reduce(attrs, {[], [], nil}, fn
        {name, {:string, value, value_meta}, _attr_meta}, {events, vkeys, meta}
        when name in @phx_event_attrs ->
          {[{value, value_meta} | events], vkeys, meta || value_meta}

        # phx-value-<key> — any value shape (static or expr); we
        # only care about the key name. Match before the catch-all
        # so static-string phx-value-foo="bar" isn't dropped.
        {"phx-value-" <> key, _attr_value, _attr_meta}, {events, vkeys, meta} ->
          {events, [key | vkeys], meta}

        _, state ->
          state
      end)

    case events do
      [] -> acc
      _ -> [{events, value_keys, node_meta} | acc]
    end
  end

  # ============================================
  # Assign-ref extraction (for ValidateTemplate)
  # ============================================
  #
  # Walks the parser tree and emits a list of `{atom_name, meta}`
  # tuples — one per `@name` occurrence anywhere an Elixir
  # expression can appear:
  #
  #   - `{:body_expr, code, meta}` — `{@field}` inline
  #   - `{:eex, code, meta}` — `<%= @field %>`
  #   - `{:eex_block, code, clauses, meta}` — `<%= for x <- @xs %>`
  #   - attr values: `{:expr, code, meta}` — `class={@theme}`
  #   - root spreads: `{:root, {:expr, code, meta}, meta}` —
  #     `<div {@spread}>`
  #
  # Extraction is regex-based on the expression source rather than
  # parsing it as Elixir AST. The existing optimism-derive code
  # already uses the same approach for similar reasons (handles
  # macro forms cleanly, no AST-walking divergence).
  #
  # Match `@name` and `@name?` — lavash allows the `?` suffix on
  # state field names (e.g. `state :is_admin?, :boolean`); the
  # assign key carries the trailing `?` too.
  @assign_ref_re ~r/@(\w+\??)/

  defp collect_assign_refs(nodes) do
    nodes
    |> walk_for_assign_refs([])
    |> Enum.uniq()
  end

  defp walk_for_assign_refs(nodes, acc) when is_list(nodes) do
    Enum.reduce(nodes, acc, &walk_node_for_assign_refs/2)
  end

  defp walk_node_for_assign_refs(
         {:block, _type, _name, attrs, children, _open_meta, _close_meta},
         acc
       ) do
    acc = extract_assign_refs_from_attrs(attrs, acc)
    walk_for_assign_refs(children, acc)
  end

  defp walk_node_for_assign_refs({:self_close, _type, _name, attrs, _meta}, acc) do
    extract_assign_refs_from_attrs(attrs, acc)
  end

  defp walk_node_for_assign_refs({:body_expr, code, meta}, acc) do
    extract_assign_refs_from_code(code, meta, acc)
  end

  defp walk_node_for_assign_refs({:eex, code, meta}, acc) do
    extract_assign_refs_from_code(code, meta, acc)
  end

  defp walk_node_for_assign_refs({:eex_block, code, clauses, meta}, acc) do
    acc = extract_assign_refs_from_code(code, meta, acc)

    Enum.reduce(clauses, acc, fn {children, _end_code, _meta}, acc ->
      walk_for_assign_refs(children, acc)
    end)
  end

  defp walk_node_for_assign_refs(_other, acc), do: acc

  defp extract_assign_refs_from_attrs(attrs, acc) do
    Enum.reduce(attrs, acc, fn
      {:root, {:expr, code, meta}, _attr_meta}, acc ->
        extract_assign_refs_from_code(code, meta, acc)

      {_name, {:expr, code, meta}, _attr_meta}, acc ->
        extract_assign_refs_from_code(code, meta, acc)

      _, acc ->
        acc
    end)
  end

  defp extract_assign_refs_from_code(code, meta, acc) when is_binary(code) do
    Regex.scan(@assign_ref_re, code)
    |> Enum.reduce(acc, fn [_, name], acc ->
      [{String.to_atom(name), meta} | acc]
    end)
  end

  defp extract_assign_refs_from_code(_code, _meta, acc), do: acc
end
