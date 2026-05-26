defmodule Lavash.Optimistic.DisplaySpanTransformer do
  @moduledoc """
  Layer-4 token transformer: wraps bare `{@field}` expressions in
  `<span data-lavash-display="field">` when `:field` is an
  optimistic state field or an optimistic calculation.

  The JS hook reads `data-lavash-display` to know which DOM node
  to swap on optimistic state change. Without the wrapping span,
  the bare interpolation just emits text — the optimistic patch
  can't find a stable element to update.

  ## What it skips

    * `metadata[:layer] == :base` — layer-2-only modules don't
      need optimistic display wrapping; the warning suppressed in
      Base mode is paired with no-op wrapping here.
    * Non-optimistic refs — `{@count}` for a `state :count, ...`
      that doesn't set `optimistic: true` is left alone. (The
      old `Lavash.Template.TokenTransformer` emitted a diagnostic
      warning here; that warning lives in
      `Lavash.Optimistic.NonOptimisticWarner` now.)
    * Bare-var refs (`{item}` from a `:for` loop) — never
      wrapped, since loop vars aren't assigns.
    * Body_exprs whose immediate parent is already a display
      wrapper or a `data-lavash-manual` block.
    * Body_exprs inside `<textarea>`, `<option>`, `<title>` — the
      browser treats body content as form values / page title
      text, so injecting a `<span>` would corrupt the payload.
  """

  @behaviour Lavash.TokenTransformer

  alias Lavash.Template.{AttrHelpers, Walker}

  @body_as_value_tags ~w(textarea option title)

  @impl true
  def transform(nodes, state) do
    metadata = state[:lavash_metadata] || %{}

    if metadata[:layer] == :base do
      nodes
    else
      Walker.walk(nodes,
        metadata: metadata,
        node_callback: &maybe_wrap/3
      )
    end
  end

  defp maybe_wrap({:body_expr, expr, expr_meta} = node, parent, metadata) do
    optimistic_fields = metadata[:optimistic_fields] || %{}
    calculations = metadata[:calculations] || %{}
    all_optimistic = Map.merge(optimistic_fields, calculations)

    case extract_optimistic_field_ref(expr, all_optimistic) do
      nil ->
        warn_if_non_optimistic_bare_ref(expr, expr_meta, metadata)
        [node]

      field_name ->
        cond do
          parent_is_display_wrapper?(parent) -> [node]
          parent_consumes_body_as_value?(parent) -> [node]
          true -> [wrap_body_expr_in_display_span(field_name, expr, expr_meta)]
        end
    end
  end

  defp maybe_wrap(node, _parent, _metadata), do: [node]

  # Diagnostic: bare {@field} for a declared-but-non-optimistic
  # field renders as plain text. The user probably meant
  # `optimistic: true`. The warning is suppressed in `:base` mode
  # because in Base mode this is the contract, not a typo — and
  # `transform/2` already short-circuits the whole walker in that
  # case, so this defp only ever runs in non-base modules.
  defp warn_if_non_optimistic_bare_ref(expr, expr_meta, metadata) do
    all_state = metadata[:all_state_fields] || %{}
    optimistic = metadata[:optimistic_fields] || %{}
    prop_field_names = metadata[:prop_field_names] || MapSet.new()

    with [_, field_str] <- Regex.run(~r/^@(\w+)$/, String.trim(expr)),
         field_atom = safe_existing_atom(field_str),
         true <- not is_nil(field_atom),
         true <- is_map_key(all_state, field_atom),
         false <- is_map_key(optimistic, field_atom),
         # Props are constant for the component's lifetime —
         # they don't have a notion of client-side optimistic
         # update. A bare `{@prop}` is the correct way to
         # render one.
         false <- MapSet.member?(prop_field_names, field_atom) do
      require Logger

      Logger.warning(
        "[lavash] {@#{field_str}} in #{metadata[:caller_file] || "template"}:" <>
          "#{expr_meta[:line] || "?"} renders as plain text — :#{field_str} is " <>
          "declared but not optimistic. Add `optimistic: true` to enable " <>
          "client-side updates."
      )
    end

    :ok
  end

  defp safe_existing_atom(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> nil
  end

  defp parent_is_display_wrapper?({:tag, _name, attrs}) do
    AttrHelpers.has_attr?(attrs, "data-lavash-display") or
      AttrHelpers.has_attr?(attrs, "data-lavash-manual")
  end

  defp parent_is_display_wrapper?(_), do: false

  defp parent_consumes_body_as_value?({:tag, name, _attrs}) when name in @body_as_value_tags,
    do: true

  defp parent_consumes_body_as_value?(_), do: false

  defp wrap_body_expr_in_display_span(field_name, expr, expr_meta) do
    line = expr_meta[:line] || 1
    column = expr_meta[:column] || 1

    open_meta = %{
      line: line,
      column: column,
      tag_name: "span",
      inner_location: {line, column + 6}
    }

    close_meta = %{
      line: line,
      column: column,
      tag_name: "span",
      inner_location: {line, column}
    }

    display_attr =
      {"data-lavash-display", {:string, field_name, %{delimiter: ?", line: line, column: column}},
       %{line: line, column: column}}

    {:block, :tag, "span", [display_attr], [{:body_expr, expr, expr_meta}], open_meta, close_meta}
  end

  defp extract_optimistic_field_ref(expr, fields) do
    trimmed = String.trim(expr)

    case Regex.run(~r/^@(\w+\??)$/, trimmed) do
      [_, field_str] ->
        field_atom = String.to_existing_atom(field_str)
        if is_map_key(fields, field_atom), do: field_str, else: nil

      _ ->
        nil
    end
  rescue
    ArgumentError -> nil
  end
end
