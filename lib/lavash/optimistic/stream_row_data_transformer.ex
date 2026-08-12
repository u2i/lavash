defmodule Lavash.Optimistic.StreamRowDataTransformer do
  @moduledoc """
  Layer-4 token transformer: injects `data-lavash-row` onto stream
  projection row elements (issue #71 phase 2).

  Keyed row predictions (`mutate`/`upsert` on a stream-backed
  projection) need the row's CURRENT data client-side — but streamed
  rows hold no client-state copy, so the row itself carries it:
  `data-lavash-row={Lavash.JSON.encode!(row)}` on the element whose
  `:for` iterates `@streams.<name>`.

  Injection is need-driven: only projections targeted by a `mutate`
  or `upsert` op get the attribute (metadata
  `:stream_row_data_fields`), so append/remove-only lists don't pay
  the per-row payload. The generated client row function renders the
  same attribute for predicted rows, keeping both sides symmetric.

  Skipped when `metadata[:layer] == :base`.
  """

  @behaviour Lavash.TokenTransformer

  alias Lavash.Template.Walker

  @impl true
  def transform(nodes, state) do
    metadata = state[:lavash_metadata] || %{}
    fields = metadata[:stream_row_data_fields] || MapSet.new()

    if metadata[:layer] == :base or MapSet.size(fields) == 0 do
      nodes
    else
      Walker.walk(nodes,
        metadata: metadata,
        node_callback: &transform_node(&1, &2, &3, fields)
      )
    end
  end

  defp transform_node(
         {:block, :tag, name, attrs, children, open_meta, close_meta},
         _parent,
         _metadata,
         fields
       ) do
    [{:block, :tag, name, maybe_inject(attrs, fields), children, open_meta, close_meta}]
  end

  defp transform_node({:self_close, :tag, name, attrs, meta}, _parent, _metadata, fields) do
    [{:self_close, :tag, name, maybe_inject(attrs, fields), meta}]
  end

  defp transform_node(node, _parent, _metadata, _fields), do: [node]

  defp maybe_inject(attrs, fields) do
    with {_, {:expr, code, expr_meta}, _} <-
           Enum.find(attrs, fn
             {":for", _, _} -> true
             _ -> false
           end),
         {:ok, row_var, field} <- parse_stream_for(code),
         true <- MapSet.member?(fields, field),
         false <- Enum.any?(attrs, fn {name, _, _} -> name == "data-lavash-row" end) do
      attrs ++
        [
          {"data-lavash-row", {:expr, "Lavash.JSON.encode!(#{row_var})", expr_meta}, expr_meta}
        ]
    else
      _ -> attrs
    end
  end

  # `{dom_id, row} <- @streams.<name>` → {:ok, "row", :name}
  defp parse_stream_for(code) do
    case Code.string_to_quoted(code) do
      {:ok,
       {:<-, _,
        [
          {{_dom_var, _, _}, {row_var, _, _}},
          {{:., _, [{:@, _, [{:streams, _, _}]}, field]}, _, _}
        ]}}
      when is_atom(row_var) and is_atom(field) ->
        {:ok, to_string(row_var), field}

      _ ->
        :error
    end
  end
end
