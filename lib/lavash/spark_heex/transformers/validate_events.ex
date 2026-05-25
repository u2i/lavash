defmodule Lavash.SparkHeex.Transformers.ValidateEvents do
  @moduledoc """
  Cross-validates the tokenized HEEx template against declared `action`
  entities.

  Walks the LV 1.2 node tree (from `Phoenix.LiveView.TagEngine.Parser`)
  looking for `phx-click` / `phx-submit` / `phx-change` / `phx-blur` /
  `phx-focus` / `phx-keydown` / `phx-keyup` attributes whose values are
  string literals, and checks each event name resolves to a declared
  `action :name`. Dynamic event names (`phx-click={@something}`) come back
  as `{:expr, ...}` and are intentionally skipped — they can't be
  validated statically.

  Demonstrates the same first-class-DSL idea as `ValidateTemplate`, but
  using the tokenized template rather than a regex over the source string.
  """
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer
  alias Spark.Error.DslError

  @event_attrs ~w(phx-click phx-submit phx-change phx-blur phx-focus phx-keydown phx-keyup)

  def after?(Lavash.SparkHeex.Transformers.ValidateTemplate), do: true
  def after?(_), do: false

  def before?(Lavash.SparkHeex.Transformers.CompileTemplate), do: true
  def before?(_), do: false

  def transform(dsl_state) do
    case Transformer.get_persisted(dsl_state, :heex_tree) do
      tree when is_list(tree) and tree != [] ->
        declared = declared_action_names(dsl_state)
        refs = collect_event_refs(tree)

        case Enum.reject(refs, fn {name, _meta} -> MapSet.member?(declared, name) end) do
          [] ->
            {:ok, dsl_state}

          bad ->
            {file, base_line} = template_file_line(dsl_state)
            {first_name, first_meta} = hd(bad)
            location = location_string(first_meta, file, base_line)

            offending =
              bad
              |> Enum.map(fn {n, _} -> to_string(n) end)
              |> Enum.uniq()
              |> Enum.join(", ")

            declared_list =
              declared
              |> MapSet.to_list()
              |> Enum.sort()
              |> Enum.map_join(", ", &to_string/1)

            declared_blurb = if declared_list == "", do: "(none)", else: declared_list

            {:error,
             DslError.exception(
               module: Transformer.get_persisted(dsl_state, :module),
               path: [:template],
               message:
                 "template references undeclared event handler(s): " <>
                   offending <>
                   " (first at " <>
                   location <>
                   "). Declared actions: " <>
                   declared_blurb <>
                   ". A phx-* attribute uses event name " <>
                   inspect(to_string(first_name)) <>
                   " but no matching `action :#{first_name}` is declared."
             )}
        end

      _ ->
        {:ok, dsl_state}
    end
  end

  defp declared_action_names(dsl_state) do
    dsl_state
    |> Transformer.get_entities([:actions])
    |> Enum.map(& &1.name)
    |> MapSet.new()
  end

  # LV 1.2 Parser emits a tree of nodes. `:block` has nested children;
  # `:self_close` is a leaf. Both carry attrs in the same shape. Other
  # node kinds (`:text`, `:body_expr`, `:eex_block`, `:eex`, `:eex_comment`)
  # don't carry event-handler attrs themselves — but `:eex_block` does
  # nest more tree nodes inside its clauses, so we descend into those too.
  defp collect_event_refs(nodes) when is_list(nodes) do
    Enum.flat_map(nodes, &collect_event_refs/1)
  end

  defp collect_event_refs({:block, _kind, _name, attrs, children, _open, _close}),
    do: refs_from_attrs(attrs) ++ collect_event_refs(children)

  defp collect_event_refs({:self_close, _kind, _name, attrs, _meta}),
    do: refs_from_attrs(attrs)

  defp collect_event_refs({:eex_block, _code, clauses, _meta}) do
    Enum.flat_map(clauses, fn {clause_nodes, _end_code, _clause_meta} ->
      collect_event_refs(clause_nodes)
    end)
  end

  defp collect_event_refs(_other), do: []

  defp refs_from_attrs(attrs) do
    Enum.flat_map(attrs, fn
      {name, {:string, literal, _value_meta}, attr_meta} when name in @event_attrs ->
        [{String.to_atom(literal), attr_meta}]

      _ ->
        []
    end)
  end

  defp template_file_line(dsl_state) do
    module = Transformer.get_persisted(dsl_state, :module)
    {_source, line} = Transformer.get_persisted(dsl_state, :heex_template)

    file =
      try do
        case module.module_info(:compile)[:source] do
          nil -> "nofile"
          source -> List.to_string(source)
        end
      rescue
        _ -> "nofile"
      end

    {file, line}
  end

  defp location_string(meta, file, base_line) do
    attr_line = (is_map(meta) && Map.get(meta, :line)) || 1
    column = (is_map(meta) && Map.get(meta, :column)) || 1
    # Tokenizer line is 1-based relative to the input we gave it; we
    # already started it at `base_line`, so use the raw line.
    line = if attr_line >= base_line, do: attr_line, else: base_line + attr_line - 1
    "#{Path.relative_to_cwd(file)}:#{line}:#{column}"
  end
end
