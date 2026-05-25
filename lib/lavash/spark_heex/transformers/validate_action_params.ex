defmodule Lavash.SparkHeex.Transformers.ValidateActionParams do
  @moduledoc """
  Per-element cross-check between `phx-value-*` attributes and the
  declared params on the corresponding `action`.

  Composes with `ValidateEvents`: that transformer ensures every literal
  event name resolves to *some* declared action. This one ensures that on
  any element with `phx-click="name"` (or `phx-submit`/`phx-change`/etc.),
  the set of `phx-value-foo` attribute keys exactly matches the declared
  `args:` list for `action :name`.

  Rules:

    * Each `phx-value-foo` key on the element must appear in the action's
      declared args. Unknown keys ⇒ DslError (typo detection).
    * Each declared arg must appear as a `phx-value-foo` key. Missing
      args ⇒ DslError.
    * Dynamic event names (`phx-click={@x}`) are skipped — the binding to
      a specific action isn't resolvable at compile time.
    * Dynamic `phx-value-foo={@x}` values are fine; only the *key* is
      checked, not the value's runtime type.
    * Event names that don't match any declared action are *not* reported
      here — `ValidateEvents` already raises in that case. We just skip
      them to avoid double-reporting.
  """
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer
  alias Spark.Error.DslError

  @event_attrs ~w(phx-click phx-submit phx-change phx-blur phx-focus phx-keydown phx-keyup)

  def after?(Lavash.SparkHeex.Transformers.ValidateEvents), do: true
  def after?(_), do: false

  def before?(Lavash.SparkHeex.Transformers.CompileTemplate), do: true
  def before?(_), do: false

  def transform(dsl_state) do
    case Transformer.get_persisted(dsl_state, :heex_tree) do
      tree when is_list(tree) and tree != [] ->
        actions = declared_actions(dsl_state)
        problems = collect_problems(tree, actions)

        case problems do
          [] ->
            {:ok, dsl_state}

          [first | _] ->
            {file, base_line} = template_file_line(dsl_state)

            {:error,
             DslError.exception(
               module: Transformer.get_persisted(dsl_state, :module),
               path: [:template],
               message: format_problem(first, file, base_line)
             )}
        end

      _ ->
        {:ok, dsl_state}
    end
  end

  defp declared_actions(dsl_state) do
    dsl_state
    |> Transformer.get_entities([:actions])
    |> Enum.into(%{}, fn a -> {a.name, a.args || []} end)
  end

  # Walk the tree, looking at each element that has a literal phx-* event
  # attribute. Returns a flat list of {kind, ...details} problems in the
  # order encountered.
  defp collect_problems(nodes, actions) when is_list(nodes) do
    Enum.flat_map(nodes, &collect_problems(&1, actions))
  end

  defp collect_problems({:block, _kind, _name, attrs, children, _open, _close}, actions) do
    problems_for_element(attrs, actions) ++ collect_problems(children, actions)
  end

  defp collect_problems({:self_close, _kind, _name, attrs, _meta}, actions) do
    problems_for_element(attrs, actions)
  end

  defp collect_problems({:eex_block, _code, clauses, _meta}, actions) do
    Enum.flat_map(clauses, fn {clause_nodes, _end_code, _clause_meta} ->
      collect_problems(clause_nodes, actions)
    end)
  end

  defp collect_problems(_other, _actions), do: []

  # For a single element's attribute list: find any literal phx-* event
  # attrs, and for each, compare the element's phx-value-* keys against
  # the action's declared args.
  defp problems_for_element(attrs, actions) do
    Enum.flat_map(attrs, fn
      {name, {:string, event_name, _value_meta}, attr_meta} when name in @event_attrs ->
        event_atom = String.to_atom(event_name)

        case Map.fetch(actions, event_atom) do
          {:ok, declared_args} ->
            compare(event_name, name, declared_args, attrs, attr_meta)

          :error ->
            # Not our problem — ValidateEvents already reports this.
            []
        end

      _ ->
        []
    end)
  end

  defp compare(event_name, event_attr, declared_args, attrs, attr_meta) do
    declared_set = MapSet.new(declared_args)
    provided = collect_phx_value_keys(attrs)
    provided_set = MapSet.new(provided)

    unknown =
      provided_set
      |> MapSet.difference(declared_set)
      |> MapSet.to_list()
      |> Enum.sort()

    missing =
      declared_set
      |> MapSet.difference(provided_set)
      |> MapSet.to_list()
      |> Enum.sort()

    cond do
      unknown != [] ->
        [{:unknown, event_name, event_attr, unknown, declared_args, attr_meta}]

      missing != [] ->
        [{:missing, event_name, event_attr, missing, declared_args, attr_meta}]

      true ->
        []
    end
  end

  defp collect_phx_value_keys(attrs) do
    Enum.flat_map(attrs, fn
      {"phx-value-" <> rest, _value, _meta} when rest != "" ->
        [String.to_atom(rest)]

      _ ->
        []
    end)
  end

  defp format_problem(
         {:unknown, event_name, event_attr, unknown, declared_args, meta},
         file,
         base_line
       ) do
    location = location_string(meta, file, base_line)
    keys = Enum.map_join(unknown, ", ", &"phx-value-#{&1}")
    declared_blurb = declared_args_blurb(declared_args)

    "element with #{event_attr}=\"#{event_name}\" passes unknown phx-value-* attribute(s): " <>
      keys <>
      " (at " <>
      location <>
      "). Action `:#{event_name}` declares args: " <>
      declared_blurb <>
      ". Check for a typo in the phx-value-* key, or add the param to `action :#{event_name}, args: [...]`."
  end

  defp format_problem(
         {:missing, event_name, event_attr, missing, declared_args, meta},
         file,
         base_line
       ) do
    location = location_string(meta, file, base_line)
    keys = Enum.map_join(missing, ", ", &"phx-value-#{&1}")
    declared_blurb = declared_args_blurb(declared_args)

    "element with #{event_attr}=\"#{event_name}\" is missing required phx-value-* attribute(s): " <>
      keys <>
      " (at " <>
      location <>
      "). Action `:#{event_name}` declares args: " <>
      declared_blurb <>
      ". Add the missing phx-value-* attribute(s) on the element, or drop the arg from `action :#{event_name}, args: [...]`."
  end

  defp declared_args_blurb([]), do: "(none)"
  defp declared_args_blurb(args), do: Enum.map_join(args, ", ", &to_string/1)

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
    line = if attr_line >= base_line, do: attr_line, else: base_line + attr_line - 1
    "#{Path.relative_to_cwd(file)}:#{line}:#{column}"
  end
end
