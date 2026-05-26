defmodule Lavash.Optimistic.ClientBindingsTransformer do
  @moduledoc """
  Layer-4 token transformer: handles `<.lavash_component>`
  invocations, propagating client-side binding metadata to child
  components.

  Two things happen on every `<.lavash_component>` call:

  1. **Inherit parent bindings.** Inside a component context (the
     caller is itself a `Lavash.Component`), inject
     `__lavash_client_bindings__={@__lavash_client_bindings__}` so
     the child sees the same binding map the parent has.

  2. **Expand `bind={[child: :parent]}` shorthand.** For each
     `{child, parent}` pair, add `child={@parent}` to the
     component's attrs so the parent's field value is passed
     down as the child's prop.

  Skipped when `metadata[:layer] == :base`. Other tag attrs and
  body_expr nodes are untouched — this transformer only cares
  about component nodes.
  """

  @behaviour Lavash.TokenTransformer

  alias Lavash.Template.{AttrHelpers, Walker}

  @lavash_components ~w(lavash_component)

  @impl true
  def transform(nodes, state) do
    metadata = state[:lavash_metadata] || %{}

    if metadata[:layer] == :base do
      nodes
    else
      Walker.walk(nodes,
        metadata: metadata,
        node_callback: &transform_node/3
      )
    end
  end

  defp transform_node(
         {:block, comp_type, name, attrs, children, open_meta, close_meta},
         _parent,
         metadata
       )
       when comp_type in [:local_component, :remote_component] do
    new_attrs = maybe_inject(name, attrs, open_meta, metadata)
    [{:block, comp_type, name, new_attrs, children, open_meta, close_meta}]
  end

  defp transform_node({:self_close, comp_type, name, attrs, meta}, _parent, metadata)
       when comp_type in [:local_component, :remote_component] do
    new_attrs = maybe_inject(name, attrs, meta, metadata)
    [{:self_close, comp_type, name, new_attrs, meta}]
  end

  defp transform_node(node, _parent, _metadata), do: [node]

  defp maybe_inject(name, attrs, meta, metadata) do
    if name in @lavash_components do
      attrs
      |> maybe_inject_client_bindings(meta, metadata[:context])
      |> maybe_inject_bound_field_values(meta, metadata)
    else
      attrs
    end
  end

  defp maybe_inject_client_bindings(attrs, meta, :component) do
    if AttrHelpers.has_attr?(attrs, "__lavash_client_bindings__") do
      attrs
    else
      attrs ++
        [
          {"__lavash_client_bindings__", {:expr, "@__lavash_client_bindings__", meta}, meta}
        ]
    end
  end

  defp maybe_inject_client_bindings(attrs, _meta, _context), do: attrs

  defp maybe_inject_bound_field_values(attrs, meta, metadata) do
    case AttrHelpers.get_attr_value(attrs, "bind") do
      {:expr, source, expr_meta} ->
        case parse_bind_pairs(source) do
          {:ok, pairs} ->
            warn_if_bind_targets_unknown(pairs, expr_meta, metadata)

            Enum.reduce(pairs, attrs, fn {child_field, parent_field}, acc ->
              child_attr_name = Atom.to_string(child_field)

              if AttrHelpers.has_attr?(acc, child_attr_name) do
                acc
              else
                acc ++
                  [
                    {child_attr_name, {:expr, "@#{parent_field}", meta}, meta}
                  ]
              end
            end)

          :error ->
            attrs
        end

      _ ->
        attrs
    end
  end

  defp warn_if_bind_targets_unknown(pairs, expr_meta, metadata) do
    all_state = metadata[:all_state_fields] || %{}

    if map_size(all_state) > 0 do
      for {child, parent} <- pairs, not is_map_key(all_state, parent) do
        require Logger

        Logger.warning(
          "[lavash] bind=#{inspect([{child, parent}])} in " <>
            "#{metadata[:caller_file] || "template"}:#{expr_meta[:line] || "?"} " <>
            "— :#{parent} is not a declared state field on " <>
            "#{inspect(metadata[:caller_module])}. The child won't receive " <>
            "parent updates."
        )
      end
    end

    :ok
  end

  defp parse_bind_pairs(source) do
    case Code.string_to_quoted(source) do
      {:ok, list} when is_list(list) ->
        if Enum.all?(list, fn
             {child, parent} when is_atom(child) and is_atom(parent) -> true
             _ -> false
           end) do
          {:ok, list}
        else
          :error
        end

      _ ->
        :error
    end
  end
end
